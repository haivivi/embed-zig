// mp4todiff converts MP4 video to compact frame-diff animation format.
//
// Usage:
//   mp4todiff [options] <input.mp4> <output.anim>
//
// Options:
//   -fps N        Target fps (default: 15, skip frames)
//   -scale N      Downscale factor (default: 2, e.g. 240→120)
//   -colors N     Palette size (default: 256, max 256)
//   -threshold N  Diff threshold (default: 4)
//
// Output format:
//   Header (10 bytes):
//     [0:2]  u16 LE  display_width (original, e.g. 240)
//     [2:4]  u16 LE  display_height
//     [4:6]  u16 LE  frame_width (scaled, e.g. 120)
//     [6:8]  u16 LE  frame_height
//     [8:10] u16 LE  frame_count
//     [10]   u8      fps
//     [11]   u8      scale factor
//     [12:14] u16 LE palette_size
//     [14:]  palette (palette_size * 2 bytes, RGB565 LE each)
//   Per frame:
//     [+0]   u16 LE  rect_count (0 = identical to previous)
//     Per rect:
//       [+0] u16 LE  x (in frame coords)
//       [+2] u16 LE  y
//       [+4] u16 LE  w
//       [+6] u16 LE  h
//       [+8] RLE data: palette-indexed pixels
//            RLE: [count-1 (u8)] [palette_index (u8)]
//            count 1-128 = literal run, repeat that index count times
//   Frame 0 is always full-screen.

package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"image"
	"image/color"
	"image/draw"
	_ "image/png"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const BLOCK_SIZE = 4

func main() {
	targetFps := flag.Int("fps", 15, "Target FPS")
	scale := flag.Int("scale", 2, "Downscale factor")
	colors := flag.Int("colors", 128, "Palette size (max 256)")
	threshold := flag.Int("threshold", 6, "Diff threshold")
	flag.Parse()

	args := flag.Args()
	if len(args) != 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s [options] <input.mp4> <output.anim>\n", os.Args[0])
		flag.PrintDefaults()
		os.Exit(1)
	}
	inPath, outPath := args[0], args[1]

	tmpDir, _ := os.MkdirTemp("", "mp4todiff")
	defer os.RemoveAll(tmpDir)

	// Extract frames at target fps
	fmt.Fprintf(os.Stderr, "Extracting frames at %d fps, scale 1/%d...\n", *targetFps, *scale)
	cmd := exec.Command("ffmpeg", "-i", inPath,
		"-vf", fmt.Sprintf("fps=%d,scale=iw/%d:ih/%d:flags=area", *targetFps, *scale, *scale),
		filepath.Join(tmpDir, "frame_%04d.png"))
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "ffmpeg failed: %v\n", err)
		os.Exit(1)
	}

	// Load frames
	entries, _ := os.ReadDir(tmpDir)
	var paths []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".png") {
			paths = append(paths, filepath.Join(tmpDir, e.Name()))
		}
	}
	sort.Strings(paths)
	if len(paths) == 0 {
		fmt.Fprintf(os.Stderr, "No frames\n")
		os.Exit(1)
	}

	first := loadFrame(paths[0])
	fw, fh := first.Bounds().Dx(), first.Bounds().Dy()
	dw, dh := fw*(*scale), fh*(*scale) // display size

	fmt.Fprintf(os.Stderr, "Display: %dx%d, Frame: %dx%d, %d frames\n", dw, dh, fw, fh, len(paths))

	// Build global palette from all frames (median cut)
	fmt.Fprintf(os.Stderr, "Building %d-color palette...\n", *colors)
	palette := buildPalette(paths, *colors)

	// Convert all frames to palette-indexed
	frames := make([][]uint8, len(paths))
	for i, p := range paths {
		img := loadFrame(p)
		frames[i] = quantize(img, palette, fw, fh)
	}

	// Write output
	out, _ := os.Create(outPath)
	defer out.Close()

	// Header
	hdr := make([]byte, 14)
	binary.LittleEndian.PutUint16(hdr[0:], uint16(dw))
	binary.LittleEndian.PutUint16(hdr[2:], uint16(dh))
	binary.LittleEndian.PutUint16(hdr[4:], uint16(fw))
	binary.LittleEndian.PutUint16(hdr[6:], uint16(fh))
	binary.LittleEndian.PutUint16(hdr[8:], uint16(len(frames)))
	hdr[10] = uint8(*targetFps)
	hdr[11] = uint8(*scale)
	binary.LittleEndian.PutUint16(hdr[12:], uint16(len(palette)))
	out.Write(hdr)

	// Palette (RGB565)
	for _, c := range palette {
		var buf [2]byte
		binary.LittleEndian.PutUint16(buf[:], c)
		out.Write(buf[:])
	}

	// Frames
	totalRLE := 0
	for i, frame := range frames {
		var rects []image.Rectangle
		if i == 0 {
			rects = []image.Rectangle{{Max: image.Point{fw, fh}}}
		} else {
			rects = findDirty(frames[i-1], frame, fw, fh, *threshold)
		}

		// rect count
		var rc [2]byte
		binary.LittleEndian.PutUint16(rc[:], uint16(len(rects)))
		out.Write(rc[:])

		for _, r := range rects {
			var rh [8]byte
			binary.LittleEndian.PutUint16(rh[0:], uint16(r.Min.X))
			binary.LittleEndian.PutUint16(rh[2:], uint16(r.Min.Y))
			binary.LittleEndian.PutUint16(rh[4:], uint16(r.Dx()))
			binary.LittleEndian.PutUint16(rh[6:], uint16(r.Dy()))
			out.Write(rh[:])

			// RLE encode rect pixels
			rle := rleEncode(frame, fw, r)
			out.Write(rle)
			totalRLE += len(rle)
		}
	}

	stat, _ := out.Stat()
	rawSize := fw * fh * 2 * len(frames) // uncompressed RGB565
	fmt.Fprintf(os.Stderr, "\nOutput: %s\n", outPath)
	fmt.Fprintf(os.Stderr, "  %d bytes (%.1f KB)\n", stat.Size(), float64(stat.Size())/1024)
	fmt.Fprintf(os.Stderr, "  Raw RGB565 would be: %.1f KB\n", float64(rawSize)/1024)
	fmt.Fprintf(os.Stderr, "  Compression: %.1f%%\n", (1-float64(stat.Size())/float64(rawSize))*100)
}

func loadFrame(path string) image.Image {
	f, _ := os.Open(path)
	defer f.Close()
	img, _, _ := image.Decode(f)
	return img
}

// Simple palette builder: collect all colors, sort by frequency, pick top N
func buildPalette(paths []string, n int) []uint16 {
	freq := make(map[uint16]int)
	// Sample every 4th frame to save time
	for i := 0; i < len(paths); i += 4 {
		img := loadFrame(paths[i])
		b := img.Bounds()
		for y := b.Min.Y; y < b.Max.Y; y++ {
			for x := b.Min.X; x < b.Max.X; x++ {
				r, g, bb, _ := img.At(x, y).RGBA()
				// Quantize to reduced RGB565 (drop lowest bits for clustering)
				r5 := uint16(uint8(r>>8) >> 3)
				g6 := uint16(uint8(g>>8) >> 2)
				b5 := uint16(uint8(bb>>8) >> 3)
				rgb565 := (r5 << 11) | (g6 << 5) | b5
				freq[rgb565]++
			}
		}
	}

	type entry struct {
		color uint16
		count int
	}
	var sorted []entry
	for c, cnt := range freq {
		sorted = append(sorted, entry{c, cnt})
	}
	sort.Slice(sorted, func(i, j int) bool { return sorted[i].count > sorted[j].count })

	palette := make([]uint16, min(n, len(sorted)))
	for i := range palette {
		palette[i] = sorted[i].color
	}
	return palette
}

// Quantize image to palette indices
func quantize(img image.Image, palette []uint16, w, h int) []uint8 {
	result := make([]uint8, w*h)
	b := img.Bounds()
	for y := 0; y < h; y++ {
		for x := 0; x < w; x++ {
			r, g, bb, _ := img.At(b.Min.X+x, b.Min.Y+y).RGBA()
			r5 := uint16(uint8(r>>8) >> 3)
			g6 := uint16(uint8(g>>8) >> 2)
			b5 := uint16(uint8(bb>>8) >> 3)
			rgb565 := (r5 << 11) | (g6 << 5) | b5
			result[y*w+x] = findNearest(palette, rgb565)
		}
	}
	return result
}

func findNearest(palette []uint16, target uint16) uint8 {
	bestIdx := 0
	bestDist := math.MaxInt32
	tr := int((target >> 11) & 0x1F)
	tg := int((target >> 5) & 0x3F)
	tb := int(target & 0x1F)
	for i, c := range palette {
		cr := int((c >> 11) & 0x1F)
		cg := int((c >> 5) & 0x3F)
		cb := int(c & 0x1F)
		d := (tr-cr)*(tr-cr) + (tg-cg)*(tg-cg) + (tb-cb)*(tb-cb)
		if d < bestDist {
			bestDist = d
			bestIdx = i
			if d == 0 {
				break
			}
		}
	}
	return uint8(bestIdx)
}

func findDirty(prev, curr []uint8, w, h, threshold int) []image.Rectangle {
	_ = threshold
	bw := (w + BLOCK_SIZE - 1) / BLOCK_SIZE
	bh := (h + BLOCK_SIZE - 1) / BLOCK_SIZE
	dirty := make([]bool, bw*bh)

	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			for dy := 0; dy < BLOCK_SIZE && by*BLOCK_SIZE+dy < h; dy++ {
				for dx := 0; dx < BLOCK_SIZE && bx*BLOCK_SIZE+dx < w; dx++ {
					idx := (by*BLOCK_SIZE+dy)*w + bx*BLOCK_SIZE + dx
					if prev[idx] != curr[idx] {
						dirty[by*bw+bx] = true
					}
				}
			}
		}
	}

	// Merge into rectangles
	var rects []image.Rectangle
	visited := make([]bool, bw*bh)
	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			if !dirty[by*bw+bx] || visited[by*bw+bx] {
				continue
			}
			ex := bx
			for ex < bw && dirty[by*bw+ex] && !visited[by*bw+ex] {
				ex++
			}
			ey := by + 1
		outer:
			for ey < bh {
				for x := bx; x < ex; x++ {
					if !dirty[ey*bw+x] {
						break outer
					}
				}
				ey++
			}
			for y := by; y < ey; y++ {
				for x := bx; x < ex; x++ {
					visited[y*bw+x] = true
				}
			}
			rects = append(rects, image.Rect(bx*BLOCK_SIZE, by*BLOCK_SIZE, min(ex*BLOCK_SIZE, w), min(ey*BLOCK_SIZE, h)))
		}
	}
	return rects
}

// RLE encode: [count-1] [index] pairs. count 1-128.
func rleEncode(frame []uint8, stride int, r image.Rectangle) []byte {
	var out []byte
	var runIdx uint8
	var runLen int

	flush := func() {
		for runLen > 0 {
			n := min(runLen, 128)
			out = append(out, uint8(n-1), runIdx)
			runLen -= n
		}
	}

	for y := r.Min.Y; y < r.Max.Y; y++ {
		for x := r.Min.X; x < r.Max.X; x++ {
			idx := frame[y*stride+x]
			if runLen == 0 {
				runIdx = idx
				runLen = 1
			} else if idx == runIdx {
				runLen++
			} else {
				flush()
				runIdx = idx
				runLen = 1
			}
		}
	}
	flush()
	return out
}

func toRGBA(img image.Image) *image.RGBA {
	b := img.Bounds()
	dst := image.NewRGBA(b)
	draw.Draw(dst, b, img, b.Min, draw.Src)
	return dst
}

func rgb565(c color.Color) uint16 {
	r, g, b, _ := c.RGBA()
	return (uint16(uint8(r>>8)>>3) << 11) | (uint16(uint8(g>>8)>>2) << 5) | uint16(uint8(b>>8)>>3)
}
