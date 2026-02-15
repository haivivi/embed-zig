// img2rgb565 converts PNG images to raw RGB565 binary files.
//
// Usage:
//   img2rgb565 <input.png> <output.rgb565>
//
// Output format: width(u16 LE) + height(u16 LE) + pixels(RGB565 LE, row-major)
// Total size: 4 + width*height*2 bytes
//
// RGB565 encoding: RRRRRGGGGGGBBBBB (little-endian u16)
// Alpha channel: pixels with alpha < 128 are written as 0x0000 (transparent black)

package main

import (
	"encoding/binary"
	"fmt"
	"image"
	_ "image/gif"
	_ "image/png"
	"os"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "Usage: %s <input.png> <output.rgb565>\n", os.Args[0])
		os.Exit(1)
	}

	inPath := os.Args[1]
	outPath := os.Args[2]

	f, err := os.Open(inPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open %s: %v\n", inPath, err)
		os.Exit(1)
	}
	defer f.Close()

	img, _, err := image.Decode(f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "decode %s: %v\n", inPath, err)
		os.Exit(1)
	}

	bounds := img.Bounds()
	w := bounds.Dx()
	h := bounds.Dy()

	// Header: width(u16 LE) + height(u16 LE)
	out, err := os.Create(outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create %s: %v\n", outPath, err)
		os.Exit(1)
	}
	defer out.Close()

	header := make([]byte, 4)
	binary.LittleEndian.PutUint16(header[0:2], uint16(w))
	binary.LittleEndian.PutUint16(header[2:4], uint16(h))
	out.Write(header)

	// Pixels: RGB565 LE, row-major
	buf := make([]byte, 2)
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			r, g, b, a := img.At(x, y).RGBA()
			// RGBA returns 16-bit values, scale to 8-bit
			r8 := uint8(r >> 8)
			g8 := uint8(g >> 8)
			b8 := uint8(b >> 8)
			a8 := uint8(a >> 8)

			var rgb565 uint16
			if a8 < 128 {
				rgb565 = 0 // transparent → black
			} else {
				rgb565 = (uint16(r8>>3) << 11) | (uint16(g8>>2) << 5) | uint16(b8>>3)
			}
			binary.LittleEndian.PutUint16(buf, rgb565)
			out.Write(buf)
		}
	}

	fmt.Fprintf(os.Stderr, "%s: %dx%d → %s (%d bytes)\n", inPath, w, h, outPath, 4+w*h*2)
}
