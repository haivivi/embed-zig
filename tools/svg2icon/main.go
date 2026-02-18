// svg2icon downloads Phosphor bold SVG icons and converts to 1-bit bitmap .icon files.
//
// Usage:
//
//	go run . -size 32 -out output_dir/ house fork-knife paw-print ...
//
// .icon file format:
//
//	byte 0: width (u8)
//	byte 1: height (u8)
//	byte 2...: 1-bit bitmap (ceil(w/8) * h bytes, MSB first, row-major)
package main

import (
	"flag"
	"fmt"
	"image"
	"image/color"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"

	"github.com/srwiley/oksvg"
	"github.com/srwiley/rasterx"
)

func main() {
	size := flag.Int("size", 32, "Output icon size (square)")
	outDir := flag.String("out", ".", "Output directory")
	flag.Parse()

	icons := flag.Args()
	if len(icons) == 0 {
		fmt.Fprintln(os.Stderr, "Usage: svg2icon -size 32 -out dir/ house fork-knife ...")
		os.Exit(1)
	}

	os.MkdirAll(*outDir, 0o755)

	for _, name := range icons {
		fmt.Printf("Processing %s...\n", name)

		svgData, err := downloadSVG(name)
		if err != nil {
			fmt.Fprintf(os.Stderr, "  ERROR downloading %s: %v\n", name, err)
			continue
		}

		img, err := rasterizeSVG(svgData, *size)
		if err != nil {
			fmt.Fprintf(os.Stderr, "  ERROR rasterizing %s: %v\n", name, err)
			continue
		}

		bitmap := threshold(img, *size)
		outPath := filepath.Join(*outDir, name+".icon")
		if err := writeIcon(outPath, *size, bitmap); err != nil {
			fmt.Fprintf(os.Stderr, "  ERROR writing %s: %v\n", outPath, err)
			continue
		}

		ones := countOnes(bitmap)
		fmt.Printf("  -> %s (%d bytes, %d/%d pixels)\n", outPath, 2+len(bitmap), ones, (*size)*(*size))
	}
}

func downloadSVG(name string) ([]byte, error) {
	url := fmt.Sprintf(
		"https://raw.githubusercontent.com/phosphor-icons/core/main/assets/bold/%s-bold.svg",
		name,
	)
	resp, err := http.Get(url)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("HTTP %d for %s", resp.StatusCode, url)
	}
	return io.ReadAll(resp.Body)
}

func rasterizeSVG(svgData []byte, size int) (*image.NRGBA, error) {
	// Replace "currentColor" with black — oksvg doesn't understand CSS currentColor
	svgStr := strings.ReplaceAll(string(svgData), "currentColor", "#000000")
	icon, err := oksvg.ReadIconStream(strings.NewReader(svgStr))
	if err != nil {
		return nil, err
	}

	icon.SetTarget(0, 0, float64(size), float64(size))

	img := image.NewNRGBA(image.Rect(0, 0, size, size))
	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			img.Set(x, y, color.White)
		}
	}

	scanner := rasterx.NewScannerGV(size, size, img, img.Bounds())
	raster := rasterx.NewDasher(size, size, scanner)
	icon.Draw(raster, 1.0)

	return img, nil
}

func threshold(img *image.NRGBA, size int) []byte {
	bytesPerRow := (size + 7) / 8
	bitmap := make([]byte, bytesPerRow*size)

	for y := 0; y < size; y++ {
		for x := 0; x < size; x++ {
			r, g, b, _ := img.At(x, y).RGBA()
			lum := (r*299 + g*587 + b*114) / 1000
			if lum < 0x8000 {
				byteIdx := y*bytesPerRow + x/8
				bit := byte(0x80) >> uint(x%8)
				bitmap[byteIdx] |= bit
			}
		}
	}
	return bitmap
}

func writeIcon(path string, size int, bitmap []byte) error {
	f, err := os.Create(path)
	if err != nil {
		return err
	}
	defer f.Close()
	f.Write([]byte{byte(size), byte(size)})
	f.Write(bitmap)
	return nil
}

func countOnes(data []byte) int {
	n := 0
	for _, b := range data {
		for b != 0 {
			n += int(b & 1)
			b >>= 1
		}
	}
	return n
}
