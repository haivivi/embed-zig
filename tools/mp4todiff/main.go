// mp4todiff converts MP4 video to frame-diff animation format.
//
// Usage:
//   mp4todiff <input.mp4> <output.anim>
//
// Requires ffmpeg in PATH.
//
// Output format:
//   Header:
//     [0:2]  u16 LE  width
//     [2:4]  u16 LE  height
//     [4:6]  u16 LE  frame_count
//     [6:8]  u16 LE  fps (frames per second)
//   Per frame:
//     [+0]   u16 LE  rect_count
//     Per rect:
//       [+0] u16 LE  x
//       [+2] u16 LE  y
//       [+4] u16 LE  w
//       [+6] u16 LE  h
//       [+8] w*h*2   RGB565 LE pixels
//
// Frame 0 is always a full-screen rect. Subsequent frames only store
// regions that changed from the previous frame (threshold-based diff).

package main

import (
	"encoding/binary"
	"fmt"
	"image"
	"image/color"
	_ "image/png"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
)

const DIFF_THRESHOLD = 4 // RGB component difference threshold
const BLOCK_SIZE = 8     // Dirty region granularity (8x8 blocks)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintf(os.Stderr, "Usage: %s <input.mp4> <output.anim>\n", os.Args[0])
		os.Exit(1)
	}

	inPath := os.Args[1]
	outPath := os.Args[2]

	// Create temp dir for frames
	tmpDir, err := os.MkdirTemp("", "mp4todiff")
	if err != nil {
		fmt.Fprintf(os.Stderr, "mktemp: %v\n", err)
		os.Exit(1)
	}
	defer os.RemoveAll(tmpDir)

	// Extract frames using ffmpeg
	fmt.Fprintf(os.Stderr, "Extracting frames from %s...\n", inPath)
	cmd := exec.Command("ffmpeg", "-i", inPath, "-vf", "format=rgb24", filepath.Join(tmpDir, "frame_%04d.png"))
	cmd.Stderr = os.Stderr
	if err := cmd.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "ffmpeg failed: %v\n", err)
		os.Exit(1)
	}

	// Read all frames
	entries, _ := os.ReadDir(tmpDir)
	var framePaths []string
	for _, e := range entries {
		if strings.HasSuffix(e.Name(), ".png") {
			framePaths = append(framePaths, filepath.Join(tmpDir, e.Name()))
		}
	}
	sort.Strings(framePaths)

	if len(framePaths) == 0 {
		fmt.Fprintf(os.Stderr, "No frames extracted\n")
		os.Exit(1)
	}

	// Load first frame to get dimensions
	firstFrame := loadFrame(framePaths[0])
	w := firstFrame.Bounds().Dx()
	h := firstFrame.Bounds().Dy()
	fps := 30 // default
	if len(framePaths) > 0 {
		// Estimate from ffprobe if needed — use 30 as default
	}

	fmt.Fprintf(os.Stderr, "%dx%d, %d frames, %d fps\n", w, h, len(framePaths), fps)

	// Open output
	out, err := os.Create(outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create output: %v\n", err)
		os.Exit(1)
	}
	defer out.Close()

	// Write header
	hdr := make([]byte, 8)
	binary.LittleEndian.PutUint16(hdr[0:2], uint16(w))
	binary.LittleEndian.PutUint16(hdr[2:4], uint16(h))
	binary.LittleEndian.PutUint16(hdr[4:6], uint16(len(framePaths)))
	binary.LittleEndian.PutUint16(hdr[6:8], uint16(fps))
	out.Write(hdr)

	// Process frames
	var prevFrame image.Image
	totalPixels := 0
	totalRects := 0

	for i, path := range framePaths {
		frame := loadFrame(path)

		var rects []image.Rectangle
		if i == 0 {
			// First frame: full screen
			rects = []image.Rectangle{{Min: image.Point{0, 0}, Max: image.Point{w, h}}}
		} else {
			rects = findDirtyRects(prevFrame, frame, w, h)
		}

		// Write frame
		var rectCount [2]byte
		binary.LittleEndian.PutUint16(rectCount[:], uint16(len(rects)))
		out.Write(rectCount[:])

		for _, r := range rects {
			rw := r.Dx()
			rh := r.Dy()

			var rectHdr [8]byte
			binary.LittleEndian.PutUint16(rectHdr[0:2], uint16(r.Min.X))
			binary.LittleEndian.PutUint16(rectHdr[2:4], uint16(r.Min.Y))
			binary.LittleEndian.PutUint16(rectHdr[4:6], uint16(rw))
			binary.LittleEndian.PutUint16(rectHdr[6:8], uint16(rh))
			out.Write(rectHdr[:])

			// Write RGB565 pixels
			buf := make([]byte, 2)
			for y := r.Min.Y; y < r.Max.Y; y++ {
				for x := r.Min.X; x < r.Max.X; x++ {
					c := frame.At(x, y)
					rr, gg, bb, _ := c.RGBA()
					r8 := uint8(rr >> 8)
					g8 := uint8(gg >> 8)
					b8 := uint8(bb >> 8)
					rgb565 := (uint16(r8>>3) << 11) | (uint16(g8>>2) << 5) | uint16(b8>>3)
					binary.LittleEndian.PutUint16(buf, rgb565)
					out.Write(buf)
				}
			}

			totalPixels += rw * rh
			totalRects++
		}

		prevFrame = frame

		if (i+1)%20 == 0 || i == len(framePaths)-1 {
			fmt.Fprintf(os.Stderr, "  frame %d/%d (%d rects)\n", i+1, len(framePaths), len(rects))
		}
	}

	// Stats
	stat, _ := out.Stat()
	fullSize := w * h * 2 * len(framePaths)
	fmt.Fprintf(os.Stderr, "Output: %s\n", outPath)
	fmt.Fprintf(os.Stderr, "  Size: %d bytes (%.1f KB)\n", stat.Size(), float64(stat.Size())/1024)
	fmt.Fprintf(os.Stderr, "  Full-frame would be: %d bytes (%.1f KB)\n", fullSize, float64(fullSize)/1024)
	fmt.Fprintf(os.Stderr, "  Compression: %.1f%%\n", (1-float64(stat.Size())/float64(fullSize))*100)
	fmt.Fprintf(os.Stderr, "  Total rects: %d, avg pixels/rect: %d\n", totalRects, totalPixels/max(totalRects, 1))
}

func loadFrame(path string) image.Image {
	f, err := os.Open(path)
	if err != nil {
		fmt.Fprintf(os.Stderr, "open %s: %v\n", path, err)
		os.Exit(1)
	}
	defer f.Close()
	img, _, err := image.Decode(f)
	if err != nil {
		fmt.Fprintf(os.Stderr, "decode %s: %v\n", path, err)
		os.Exit(1)
	}
	return img
}

func findDirtyRects(prev, curr image.Image, w, h int) []image.Rectangle {
	// Mark dirty blocks
	bw := (w + BLOCK_SIZE - 1) / BLOCK_SIZE
	bh := (h + BLOCK_SIZE - 1) / BLOCK_SIZE
	dirty := make([]bool, bw*bh)

	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			if isBlockDirty(prev, curr, bx*BLOCK_SIZE, by*BLOCK_SIZE, w, h) {
				dirty[by*bw+bx] = true
			}
		}
	}

	// Merge adjacent dirty blocks into rectangles (simple row-merge)
	var rects []image.Rectangle
	visited := make([]bool, bw*bh)

	for by := 0; by < bh; by++ {
		for bx := 0; bx < bw; bx++ {
			idx := by*bw + bx
			if !dirty[idx] || visited[idx] {
				continue
			}

			// Extend right
			ex := bx
			for ex < bw && dirty[by*bw+ex] && !visited[by*bw+ex] {
				ex++
			}

			// Extend down
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

			// Mark visited
			for y := by; y < ey; y++ {
				for x := bx; x < ex; x++ {
					visited[y*bw+x] = true
				}
			}

			r := image.Rect(
				bx*BLOCK_SIZE, by*BLOCK_SIZE,
				min(ex*BLOCK_SIZE, w), min(ey*BLOCK_SIZE, h),
			)
			rects = append(rects, r)
		}
	}

	return rects
}

func isBlockDirty(prev, curr image.Image, bx, by, w, h int) bool {
	for y := by; y < min(by+BLOCK_SIZE, h); y++ {
		for x := bx; x < min(bx+BLOCK_SIZE, w); x++ {
			pr, pg, pb, _ := prev.At(x, y).RGBA()
			cr, cg, cb, _ := curr.At(x, y).RGBA()
			dr := absDiff(uint8(pr>>8), uint8(cr>>8))
			dg := absDiff(uint8(pg>>8), uint8(cg>>8))
			db := absDiff(uint8(pb>>8), uint8(cb>>8))
			if dr > DIFF_THRESHOLD || dg > DIFF_THRESHOLD || db > DIFF_THRESHOLD {
				return true
			}
		}
	}
	return false
}

func absDiff(a, b uint8) uint8 {
	if a > b {
		return a - b
	}
	return b - a
}

func rgbToColor(r, g, b uint8) color.RGBA {
	return color.RGBA{r, g, b, 255}
}
