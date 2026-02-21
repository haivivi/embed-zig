// img2rgb565 converts PNG images to raw RGBA5658 binary files.
//
// Usage:
//   img2rgb565 <input.png> <output.rgb565>
//
// Output format:
//   [0:2]  u16 LE  width
//   [2:4]  u16 LE  height
//   [4:5]  u8      bytes_per_pixel (2=RGB565 opaque, 3=RGBA5658 with alpha)
//   [5:]   pixels  row-major
//
// If all pixels are fully opaque (alpha=255), outputs 2 bpp (RGB565 only).
// If any pixel has alpha < 255, outputs 3 bpp (RGB565 + alpha byte).
//
// RGB565 encoding: RRRRRGGGGGGBBBBB (little-endian u16)

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

	// First pass: check if any pixel has alpha < 255
	hasAlpha := false
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			_, _, _, a := img.At(x, y).RGBA()
			if uint8(a>>8) < 255 {
				hasAlpha = true
				break
			}
		}
		if hasAlpha {
			break
		}
	}

	bpp := 2
	if hasAlpha {
		bpp = 3
	}

	out, err := os.Create(outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create %s: %v\n", outPath, err)
		os.Exit(1)
	}
	defer out.Close()

	// Header: width(u16 LE) + height(u16 LE) + bpp(u8)
	header := make([]byte, 5)
	binary.LittleEndian.PutUint16(header[0:2], uint16(w))
	binary.LittleEndian.PutUint16(header[2:4], uint16(h))
	header[4] = byte(bpp)
	out.Write(header)

	// Pixels
	buf := make([]byte, 3) // max 3 bytes per pixel
	for y := bounds.Min.Y; y < bounds.Max.Y; y++ {
		for x := bounds.Min.X; x < bounds.Max.X; x++ {
			r, g, b, a := img.At(x, y).RGBA()
			r8 := uint8(r >> 8)
			g8 := uint8(g >> 8)
			b8 := uint8(b >> 8)
			a8 := uint8(a >> 8)

			rgb565 := (uint16(r8>>3) << 11) | (uint16(g8>>2) << 5) | uint16(b8>>3)
			binary.LittleEndian.PutUint16(buf[0:2], rgb565)

			if bpp == 3 {
				buf[2] = a8
				out.Write(buf[0:3])
			} else {
				out.Write(buf[0:2])
			}
		}
	}

	mode := "RGB565"
	if hasAlpha {
		mode = "RGBA5658"
	}
	totalSize := 5 + w*h*bpp
	fmt.Fprintf(os.Stderr, "%s: %dx%d %s → %s (%d bytes)\n", inPath, w, h, mode, outPath, totalSize)
}
