/**
 * @file cb_helper.m
 * @brief CoreBluetooth Objective-C implementation
 *
 * Implements the C API defined in cb_helper.h using Apple's CoreBluetooth framework.
 * Uses dispatch_semaphore for blocking operations (read/write from Zig threads).
 */

#import <CoreBluetooth/CoreBluetooth.h>
#import <CoreFoundation/CoreFoundation.h>
#import <dispatch/dispatch.h>
#include "cb_helper.h"
#include <string.h>
#include <stdio.h>

// ============================================================================
// Helpers
// ============================================================================

static CBUUID *uuidFromString(const char *str) {
    return [CBUUID UUIDWithString:[NSString stringWithUTF8String:str]];
}

// ============================================================================
// Static callbacks (used by both classes)
// ============================================================================

static cb_read_callback_t s_read_cb = NULL;
static cb_write_callback_t s_write_cb = NULL;
static cb_subscribe_callback_t s_subscribe_cb = NULL;
static cb_connection_callback_t s_peripheral_conn_cb = NULL;
static cb_device_found_callback_t s_device_found_cb = NULL;
static cb_notification_callback_t s_notification_cb = NULL;
static cb_connection_callback_t s_central_conn_cb = NULL;

// ============================================================================
// Peripheral Manager (GATT Server)
// ============================================================================

@interface CBPeripheralHelper : NSObject <CBPeripheralManagerDelegate>
@property (nonatomic, strong) CBPeripheralManager *manager;
@property (nonatomic, strong) NSMutableArray<CBMutableService *> *services;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBMutableCharacteristic *> *charMap;
@property (nonatomic, strong) NSMutableSet<CBCentral *> *subscribedCentrals;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, strong) dispatch_semaphore_t readySem;
// Bug 1 fix: flow control for updateValue
@property (nonatomic, assign) BOOL readyToUpdate;
@property (nonatomic, strong) dispatch_semaphore_t updateSem;
@end

@implementation CBPeripheralHelper

- (instancetype)init {
    self = [super init];
    if (self) {
        _services = [NSMutableArray new];
        _charMap = [NSMutableDictionary new];
        _subscribedCentrals = [NSMutableSet new];
        _ready = NO;
        _readyToUpdate = YES; // initially ready
        _readySem = dispatch_semaphore_create(0);
        _updateSem = dispatch_semaphore_create(0);
        _manager = [[CBPeripheralManager alloc] initWithDelegate:self queue:nil];
    }
    return self;
}

- (void)peripheralManagerDidUpdateState:(CBPeripheralManager *)peripheral {
    if (peripheral.state == CBManagerStatePoweredOn) {
        _ready = YES;
        dispatch_semaphore_signal(_readySem);
    }
}

// Bug 1 fix: called by CoreBluetooth when transmit queue has space again
- (void)peripheralManagerIsReadyToUpdateSubscribers:(CBPeripheralManager *)peripheral {
    _readyToUpdate = YES;
    dispatch_semaphore_signal(_updateSem);
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
    didReceiveReadRequest:(CBATTRequest *)request {
    NSString *key = [NSString stringWithFormat:@"%@/%@",
        request.characteristic.service.UUID.UUIDString,
        request.characteristic.UUID.UUIDString];

    if (s_read_cb) {
        uint8_t buf[512];
        uint16_t len = 0;
        const char *svc = request.characteristic.service.UUID.UUIDString.UTF8String;
        const char *chr = request.characteristic.UUID.UUIDString.UTF8String;
        s_read_cb(svc, chr, buf, &len, 512);
        request.value = [NSData dataWithBytes:buf length:len];
        [peripheral respondToRequest:request withResult:CBATTErrorSuccess];
    } else {
        [peripheral respondToRequest:request withResult:CBATTErrorRequestNotSupported];
    }
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
    didReceiveWriteRequests:(NSArray<CBATTRequest *> *)requests {
    for (CBATTRequest *request in requests) {
        if (s_write_cb && request.value) {
            const char *svc = request.characteristic.service.UUID.UUIDString.UTF8String;
            const char *chr = request.characteristic.UUID.UUIDString.UTF8String;
            s_write_cb(svc, chr, request.value.bytes, (uint16_t)request.value.length);
        }
        [peripheral respondToRequest:request withResult:CBATTErrorSuccess];
    }
}

// Bug 3 fix: fire connection callback on first subscribe
- (void)peripheralManager:(CBPeripheralManager *)peripheral
    central:(CBCentral *)central didSubscribeToCharacteristic:(CBCharacteristic *)characteristic {
    BOOL wasEmpty = (_subscribedCentrals.count == 0);
    [_subscribedCentrals addObject:central];
    // Fire connection callback when first central subscribes
    if (wasEmpty && _subscribedCentrals.count > 0 && s_peripheral_conn_cb) {
        s_peripheral_conn_cb(true);
    }
    if (s_subscribe_cb) {
        const char *svc = characteristic.service.UUID.UUIDString.UTF8String;
        const char *chr = characteristic.UUID.UUIDString.UTF8String;
        s_subscribe_cb(svc, chr, true);
    }
}

// Bug 3 fix: fire disconnection callback when all centrals unsubscribe
- (void)peripheralManager:(CBPeripheralManager *)peripheral
    central:(CBCentral *)central didUnsubscribeFromCharacteristic:(CBCharacteristic *)characteristic {
    [_subscribedCentrals removeObject:central];
    if (s_subscribe_cb) {
        const char *svc = characteristic.service.UUID.UUIDString.UTF8String;
        const char *chr = characteristic.UUID.UUIDString.UTF8String;
        s_subscribe_cb(svc, chr, false);
    }
    // Fire disconnection callback when no centrals remain
    if (_subscribedCentrals.count == 0 && s_peripheral_conn_cb) {
        s_peripheral_conn_cb(false);
    }
}

- (void)peripheralManager:(CBPeripheralManager *)peripheral
    didAddService:(CBService *)service error:(NSError *)error {
    if (error) {
        fprintf(stderr, "[cb] Failed to add service: %s\n", error.localizedDescription.UTF8String);
    }
}

- (void)peripheralManagerDidStartAdvertising:(CBPeripheralManager *)peripheral error:(NSError *)error {
    if (error) {
        fprintf(stderr, "[cb] Advertising failed: %s\n", error.localizedDescription.UTF8String);
    }
}

@end

// ============================================================================
// Central Manager (GATT Client)
// ============================================================================

@interface CBCentralHelper : NSObject <CBCentralManagerDelegate, CBPeripheralDelegate>
@property (nonatomic, strong) CBCentralManager *manager;
@property (nonatomic, strong) CBPeripheral *connectedPeripheral;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBPeripheral *> *discoveredPeripherals;
@property (nonatomic, strong) NSMutableDictionary<NSString *, CBCharacteristic *> *discoveredChars;
@property (nonatomic, assign) BOOL ready;
@property (nonatomic, strong) dispatch_semaphore_t readySem;
@property (nonatomic, strong) dispatch_semaphore_t connectSem;
@property (nonatomic, strong) dispatch_semaphore_t readSem;
@property (nonatomic, strong) dispatch_semaphore_t writeSem;
@property (nonatomic, strong) dispatch_semaphore_t discoverSem;
@property (nonatomic, strong) NSData *lastReadValue;
@property (nonatomic, assign) int lastError;
@property (nonatomic, assign) BOOL opDone;
@property (nonatomic, assign) BOOL writeNoRspReady;
@end

@implementation CBCentralHelper

- (instancetype)init {
    self = [super init];
    if (self) {
        _discoveredPeripherals = [NSMutableDictionary new];
        _discoveredChars = [NSMutableDictionary new];
        _ready = NO;
        _readySem = dispatch_semaphore_create(0);
        _connectSem = dispatch_semaphore_create(0);
        _readSem = dispatch_semaphore_create(0);
        _writeSem = dispatch_semaphore_create(0);
        _discoverSem = dispatch_semaphore_create(0);
        _manager = [[CBCentralManager alloc] initWithDelegate:self queue:nil];
    }
    return self;
}

- (void)centralManagerDidUpdateState:(CBCentralManager *)central {
    if (central.state == CBManagerStatePoweredOn) {
        _ready = YES;
        dispatch_semaphore_signal(_readySem);
    }
}

- (void)centralManager:(CBCentralManager *)central
    didDiscoverPeripheral:(CBPeripheral *)peripheral
    advertisementData:(NSDictionary *)advertisementData
    RSSI:(NSNumber *)RSSI {

    NSString *name = advertisementData[CBAdvertisementDataLocalNameKey]
                     ?: peripheral.name ?: @"";
    NSString *uuid = peripheral.identifier.UUIDString;

    _discoveredPeripherals[uuid] = peripheral;

    if (s_device_found_cb) {
        s_device_found_cb(name.UTF8String, uuid.UTF8String, RSSI.intValue);
    }
}

- (void)centralManager:(CBCentralManager *)central
    didConnectPeripheral:(CBPeripheral *)peripheral {
    _connectedPeripheral = peripheral;
    peripheral.delegate = self;
    // Bug 2 fix: clear stale char cache before fresh discovery
    [_discoveredChars removeAllObjects];
    // Discover all services (fresh, not from cache)
    [peripheral discoverServices:nil];
}

- (void)centralManager:(CBCentralManager *)central
    didFailToConnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    _lastError = -1;
    dispatch_semaphore_signal(_connectSem);
}

- (void)centralManager:(CBCentralManager *)central
    didDisconnectPeripheral:(CBPeripheral *)peripheral error:(NSError *)error {
    _connectedPeripheral = nil;
    if (s_central_conn_cb) s_central_conn_cb(false);
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverServices:(NSError *)error {
    for (CBService *svc in peripheral.services) {
        [peripheral discoverCharacteristics:nil forService:svc];
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didDiscoverCharacteristicsForService:(CBService *)service error:(NSError *)error {
    for (CBCharacteristic *chr in service.characteristics) {
        // Bug 2 fix: normalize UUID keys to uppercase for consistent matching
        NSString *key = [NSString stringWithFormat:@"%@/%@",
            service.UUID.UUIDString.uppercaseString,
            chr.UUID.UUIDString.uppercaseString];
        _discoveredChars[key] = chr;
        fprintf(stderr, "[cb] discovered char key: '%s'\n", key.UTF8String);
    }
    // Check if all services discovered
    BOOL allDone = YES;
    for (CBService *svc in peripheral.services) {
        if (!svc.characteristics) { allDone = NO; break; }
    }
    if (allDone) {
        if (s_central_conn_cb) s_central_conn_cb(true);
        dispatch_semaphore_signal(_connectSem);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    if (characteristic.isNotifying && s_notification_cb) {
        const char *svc = characteristic.service.UUID.UUIDString.UTF8String;
        const char *chr = characteristic.UUID.UUIDString.UTF8String;
        s_notification_cb(svc, chr, characteristic.value.bytes, (uint16_t)characteristic.value.length);
    } else {
        _lastReadValue = characteristic.value;
        _lastError = error ? -1 : 0;
        dispatch_semaphore_signal(_readSem);
    }
}

- (void)peripheral:(CBPeripheral *)peripheral
    didWriteValueForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    _lastError = error ? -1 : 0;
    _opDone = YES;
}

- (void)peripheral:(CBPeripheral *)peripheral
    didUpdateNotificationStateForCharacteristic:(CBCharacteristic *)characteristic error:(NSError *)error {
    _lastError = error ? -1 : 0;
    _opDone = YES;
}

// Flow control for writeWithoutResponse (same pattern as peripheral notify)
- (void)peripheralIsReadyToSendWriteWithoutResponse:(CBPeripheral *)peripheral {
    _writeNoRspReady = YES;
}

@end

// ============================================================================
// Static instances
// ============================================================================

static CBPeripheralHelper *s_peripheral = nil;
static CBCentralHelper *s_central = nil;

// ============================================================================
// Helper: normalize UUID key to uppercase for consistent matching
// ============================================================================

static NSString *normalizedKey(const char *svc_uuid, const char *chr_uuid) {
    return [[NSString stringWithFormat:@"%s/%s", svc_uuid, chr_uuid] uppercaseString];
}

// ============================================================================
// Peripheral C API
// ============================================================================

void cb_peripheral_set_read_callback(cb_read_callback_t cb) { s_read_cb = cb; }
void cb_peripheral_set_write_callback(cb_write_callback_t cb) { s_write_cb = cb; }
void cb_peripheral_set_subscribe_callback(cb_subscribe_callback_t cb) { s_subscribe_cb = cb; }
void cb_peripheral_set_connection_callback(cb_connection_callback_t cb) { s_peripheral_conn_cb = cb; }

int cb_peripheral_init(void) {
    s_peripheral = [[CBPeripheralHelper alloc] init];
    // Pump run loop while waiting for Bluetooth to be ready (up to 5s)
    for (int i = 0; i < 50 && !s_peripheral.ready; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return s_peripheral.ready ? 0 : -1;
}

int cb_peripheral_add_service(const char *svc_uuid,
                              const char **chr_uuids,
                              const uint8_t *chr_props,
                              uint16_t chr_count) {
    if (!s_peripheral || !s_peripheral.ready) return -1;

    NSMutableArray<CBMutableCharacteristic *> *chars = [NSMutableArray new];

    for (uint16_t i = 0; i < chr_count; i++) {
        CBCharacteristicProperties props = 0;
        CBAttributePermissions perms = 0;

        if (chr_props[i] & CB_PROP_READ) {
            props |= CBCharacteristicPropertyRead;
            perms |= CBAttributePermissionsReadable;
        }
        if (chr_props[i] & CB_PROP_WRITE) {
            props |= CBCharacteristicPropertyWrite;
            perms |= CBAttributePermissionsWriteable;
        }
        if (chr_props[i] & CB_PROP_WRITE_NO_RSP) {
            props |= CBCharacteristicPropertyWriteWithoutResponse;
            perms |= CBAttributePermissionsWriteable;
        }
        if (chr_props[i] & CB_PROP_NOTIFY) {
            props |= CBCharacteristicPropertyNotify;
        }
        if (chr_props[i] & CB_PROP_INDICATE) {
            props |= CBCharacteristicPropertyIndicate;
        }

        CBMutableCharacteristic *chr = [[CBMutableCharacteristic alloc]
            initWithType:uuidFromString(chr_uuids[i])
            properties:props
            value:nil
            permissions:perms];

        [chars addObject:chr];

        // Bug 2 fix: use normalized (uppercase) keys for charMap
        NSString *key = normalizedKey(svc_uuid, chr_uuids[i]);
        s_peripheral.charMap[key] = chr;
    }

    CBMutableService *service = [[CBMutableService alloc]
        initWithType:uuidFromString(svc_uuid) primary:YES];
    service.characteristics = chars;

    [s_peripheral.services addObject:service];
    [s_peripheral.manager addService:service];

    return 0;
}

int cb_peripheral_start_advertising(const char *name) {
    if (!s_peripheral || !s_peripheral.ready) return -1;

    NSMutableArray *uuids = [NSMutableArray new];
    for (CBMutableService *svc in s_peripheral.services) {
        [uuids addObject:svc.UUID];
    }

    [s_peripheral.manager startAdvertising:@{
        CBAdvertisementDataLocalNameKey: [NSString stringWithUTF8String:name],
        CBAdvertisementDataServiceUUIDsKey: uuids,
    }];

    return 0;
}

void cb_peripheral_stop_advertising(void) {
    if (s_peripheral) {
        [s_peripheral.manager stopAdvertising];
    }
}

// Original non-blocking notify (returns immediately)
int cb_peripheral_notify(const char *svc_uuid, const char *chr_uuid,
                         const uint8_t *data, uint16_t len) {
    if (!s_peripheral) return -1;

    NSString *key = normalizedKey(svc_uuid, chr_uuid);
    CBMutableCharacteristic *chr = s_peripheral.charMap[key];
    if (!chr) return -2;

    NSData *value = [NSData dataWithBytes:data length:len];
    BOOL ok = [s_peripheral.manager updateValue:value forCharacteristic:chr
               onSubscribedCentrals:nil];
    return ok ? 0 : -3;
}

// Bug 1 fix: blocking notify — waits for queue space via
// peripheralManagerIsReadyToUpdateSubscribers delegate callback.
int cb_peripheral_notify_blocking(const char *svc_uuid, const char *chr_uuid,
                                  const uint8_t *data, uint16_t len,
                                  uint32_t timeout_ms) {
    if (!s_peripheral) return -1;

    NSString *key = normalizedKey(svc_uuid, chr_uuid);
    CBMutableCharacteristic *chr = s_peripheral.charMap[key];
    if (!chr) return -2;

    NSData *value = [NSData dataWithBytes:data length:len];

    // Try sending — if queue has space, returns YES immediately
    BOOL ok = [s_peripheral.manager updateValue:value forCharacteristic:chr
               onSubscribedCentrals:nil];
    if (ok) return 0;

    // Queue full — wait for peripheralManagerIsReadyToUpdateSubscribers
    // which sets readyToUpdate=YES and signals updateSem.
    s_peripheral.readyToUpdate = NO;

    // Pump run loop in tight increments until ready or timeout
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:timeout_ms / 1000.0];
    while (!s_peripheral.readyToUpdate) {
        // Process one run loop source then return immediately
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0001, true); // 0.1ms max
        if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
            return -4; // timeout
        }
    }

    // Retry after queue drained
    ok = [s_peripheral.manager updateValue:value forCharacteristic:chr
          onSubscribedCentrals:nil];
    return ok ? 0 : -3;
}

void cb_peripheral_deinit(void) {
    if (s_peripheral) {
        [s_peripheral.manager stopAdvertising];
        for (CBMutableService *svc in s_peripheral.services) {
            [s_peripheral.manager removeService:svc];
        }
        s_peripheral = nil;
    }
}

// ============================================================================
// Central C API
// ============================================================================

void cb_central_set_device_found_callback(cb_device_found_callback_t cb) { s_device_found_cb = cb; }
void cb_central_set_notification_callback(cb_notification_callback_t cb) { s_notification_cb = cb; }
void cb_central_set_connection_callback(cb_connection_callback_t cb) { s_central_conn_cb = cb; }

int cb_central_init(void) {
    s_central = [[CBCentralHelper alloc] init];
    for (int i = 0; i < 50 && !s_central.ready; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }
    return s_central.ready ? 0 : -1;
}

int cb_central_scan_start(const char *service_uuid_filter) {
    if (!s_central || !s_central.ready) return -1;

    NSArray *uuids = nil;
    if (service_uuid_filter) {
        uuids = @[uuidFromString(service_uuid_filter)];
    }

    [s_central.manager scanForPeripheralsWithServices:uuids options:@{
        CBCentralManagerScanOptionAllowDuplicatesKey: @NO,
    }];
    return 0;
}

void cb_central_scan_stop(void) {
    if (s_central) {
        [s_central.manager stopScan];
    }
}

int cb_central_connect(const char *peripheral_uuid) {
    if (!s_central) return -1;

    NSString *uuid = [NSString stringWithUTF8String:peripheral_uuid];
    CBPeripheral *peripheral = s_central.discoveredPeripherals[uuid];
    if (!peripheral) return -2;

    s_central.lastError = 0;
    [s_central.manager connectPeripheral:peripheral options:nil];

    // Pump run loop while waiting for connection + service discovery
    for (int i = 0; i < 100 && !s_central.connectedPeripheral; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    return s_central.connectedPeripheral ? 0 : -3;
}

// Bug 2 fix: force re-discovery by disconnecting and reconnecting.
// Clears CoreBluetooth's GATT cache for this peripheral.
int cb_central_rediscover(void) {
    if (!s_central || !s_central.connectedPeripheral) return -1;

    CBPeripheral *peripheral = s_central.connectedPeripheral;

    // Disconnect
    [s_central.manager cancelPeripheralConnection:peripheral];
    for (int i = 0; i < 20 && s_central.connectedPeripheral; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    // Clear stale cache
    [s_central.discoveredChars removeAllObjects];

    // Reconnect
    s_central.lastError = 0;
    [s_central.manager connectPeripheral:peripheral options:nil];

    for (int i = 0; i < 100 && !s_central.connectedPeripheral; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    return s_central.connectedPeripheral ? 0 : -3;
}

void cb_central_disconnect(void) {
    if (s_central && s_central.connectedPeripheral) {
        [s_central.manager cancelPeripheralConnection:s_central.connectedPeripheral];
    }
}

// Helper: find a characteristic by normalized (uppercase) key
static CBCharacteristic *findChar(const char *svc_uuid, const char *chr_uuid) {
    NSString *key = normalizedKey(svc_uuid, chr_uuid);
    CBCharacteristic *chr = s_central.discoveredChars[key];
    if (!chr) {
        fprintf(stderr, "[cb] char not found for key '%s'\n", key.UTF8String);
        fprintf(stderr, "[cb]   available keys (%lu):\n",
                (unsigned long)s_central.discoveredChars.count);
        for (NSString *k in s_central.discoveredChars) {
            fprintf(stderr, "[cb]     '%s'\n", k.UTF8String);
        }
    }
    return chr;
}

int cb_central_read(const char *svc_uuid, const char *chr_uuid,
                    uint8_t *out, uint16_t *out_len, uint16_t max_len) {
    if (!s_central || !s_central.connectedPeripheral) return -1;

    CBCharacteristic *chr = findChar(svc_uuid, chr_uuid);
    if (!chr) return -2;

    s_central.lastReadValue = nil;
    s_central.lastError = 0;
    [s_central.connectedPeripheral readValueForCharacteristic:chr];

    for (int i = 0; i < 50 && !s_central.lastReadValue && s_central.lastError == 0; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    if (s_central.lastError != 0 || !s_central.lastReadValue) return -3;

    uint16_t len = (uint16_t)s_central.lastReadValue.length;
    if (len > max_len) len = max_len;
    memcpy(out, s_central.lastReadValue.bytes, len);
    *out_len = len;
    return 0;
}

int cb_central_write(const char *svc_uuid, const char *chr_uuid,
                     const uint8_t *data, uint16_t len) {
    if (!s_central || !s_central.connectedPeripheral) return -1;

    CBCharacteristic *chr = findChar(svc_uuid, chr_uuid);
    if (!chr) return -2;

    NSData *value = [NSData dataWithBytes:data length:len];
    s_central.lastError = 0;
    s_central.opDone = NO;
    [s_central.connectedPeripheral writeValue:value forCharacteristic:chr
     type:CBCharacteristicWriteWithResponse];

    for (int i = 0; i < 50 && !s_central.opDone && s_central.lastError == 0; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    return s_central.lastError;
}

int cb_central_write_no_response(const char *svc_uuid, const char *chr_uuid,
                                 const uint8_t *data, uint16_t len) {
    if (!s_central || !s_central.connectedPeripheral) return -1;

    CBCharacteristic *chr = findChar(svc_uuid, chr_uuid);
    if (!chr) return -2;

    NSData *value = [NSData dataWithBytes:data length:len];

    // Flow control: wait until peripheral is ready to accept writes
    if (!s_central.connectedPeripheral.canSendWriteWithoutResponse) {
        s_central.writeNoRspReady = NO;
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:10.0];
        while (!s_central.writeNoRspReady) {
            CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.0001, true);
            if ([[NSDate date] compare:deadline] != NSOrderedAscending) {
                return -4; // timeout
            }
        }
    }

    [s_central.connectedPeripheral writeValue:value forCharacteristic:chr
     type:CBCharacteristicWriteWithoutResponse];
    return 0;
}

int cb_central_subscribe(const char *svc_uuid, const char *chr_uuid) {
    if (!s_central || !s_central.connectedPeripheral) return -1;

    CBCharacteristic *chr = findChar(svc_uuid, chr_uuid);
    if (!chr) return -2;

    s_central.lastError = 0;
    s_central.opDone = NO;
    [s_central.connectedPeripheral setNotifyValue:YES forCharacteristic:chr];

    for (int i = 0; i < 50 && !s_central.opDone && s_central.lastError == 0; i++) {
        [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
    }

    return s_central.lastError;
}

int cb_central_unsubscribe(const char *svc_uuid, const char *chr_uuid) {
    if (!s_central || !s_central.connectedPeripheral) return -1;

    CBCharacteristic *chr = findChar(svc_uuid, chr_uuid);
    if (!chr) return -2;

    [s_central.connectedPeripheral setNotifyValue:NO forCharacteristic:chr];
    return 0;
}

void cb_central_deinit(void) {
    if (s_central) {
        cb_central_disconnect();
        s_central = nil;
    }
}

// ============================================================================
// Run Loop
// ============================================================================

void cb_run_loop_once(uint32_t timeout_ms) {
    NSDate *date = [NSDate dateWithTimeIntervalSinceNow:timeout_ms / 1000.0];
    [[NSRunLoop currentRunLoop] runUntilDate:date];
}
