// ttf2bitmapfont renders specific characters from a TTF font into a bitmap font file.
//
// Usage:
//   ttf2bitmapfont -ttf NotoSansSC-Bold.ttf -size 24 -chars "奥特集结超能驯化守护联络积分设置炽焰跃动深渊征途超能反击量子方域屏幕亮度指示灯按键提示重置设备信息绑定Sim卡系统语言敬请期待ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789:. " -out font24.bin
//
// Output format:
//   [0]    u8  glyph_w
//   [1]    u8  glyph_h
//   [2:4]  u16 LE char_count
//   [4:4+char_count*4] codepoints (u32 LE each, sorted)
//   [...]  bitmap data (1bpp, row-major, MSB first, ceil(glyph_w/8)*glyph_h per glyph)

package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"image"
	"image/draw"
	"os"
	"sort"
	"unicode/utf8"

	"golang.org/x/image/font"
	"golang.org/x/image/font/opentype"
	"golang.org/x/image/math/fixed"
)

func main() {
	ttfPath := flag.String("ttf", "", "TTF font file path")
	size := flag.Float64("size", 24, "Font size in pixels")
	chars := flag.String("chars", "", "Characters to render")
	outPath := flag.String("out", "font.bin", "Output binary file")
	flag.Parse()

	if *ttfPath == "" || *chars == "" {
		flag.Usage()
		os.Exit(1)
	}

	// Load TTF
	ttfData, err := os.ReadFile(*ttfPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "read ttf: %v\n", err)
		os.Exit(1)
	}

	ft, err := opentype.Parse(ttfData)
	if err != nil {
		fmt.Fprintf(os.Stderr, "parse ttf: %v\n", err)
		os.Exit(1)
	}

	face, err := opentype.NewFace(ft, &opentype.FaceOptions{
		Size:    *size,
		DPI:     72,
		Hinting: font.HintingFull,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "create face: %v\n", err)
		os.Exit(1)
	}
	defer face.Close()

	// Collect unique codepoints
	cpSet := make(map[rune]bool)
	for _, r := range *chars {
		cpSet[r] = true
	}
	var codepoints []rune
	for r := range cpSet {
		codepoints = append(codepoints, r)
	}
	sort.Slice(codepoints, func(i, j int) bool { return codepoints[i] < codepoints[j] })

	// Determine glyph dimensions (fixed-width: use max advance)
	metrics := face.Metrics()
	glyphH := int((metrics.Ascent + metrics.Descent).Ceil())
	ascent := metrics.Ascent.Ceil()

	// Calculate max width from all characters
	glyphW := 0
	for _, cp := range codepoints {
		adv, ok := face.GlyphAdvance(cp)
		if !ok {
			continue
		}
		w := adv.Ceil()
		if w > glyphW {
			glyphW = w
		}
	}

	if glyphW == 0 || glyphH == 0 {
		fmt.Fprintf(os.Stderr, "no renderable characters\n")
		os.Exit(1)
	}

	bytesPerRow := (glyphW + 7) / 8
	glyphSize := bytesPerRow * glyphH

	fmt.Fprintf(os.Stderr, "Font: %dx%d, %d chars, %d bytes/glyph\n",
		glyphW, glyphH, len(codepoints), glyphSize)

	// Render each glyph
	out, err := os.Create(*outPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "create output: %v\n", err)
		os.Exit(1)
	}
	defer out.Close()

	// Header
	header := make([]byte, 4)
	header[0] = byte(glyphW)
	header[1] = byte(glyphH)
	binary.LittleEndian.PutUint16(header[2:4], uint16(len(codepoints)))
	out.Write(header)

	// Codepoint table
	for _, cp := range codepoints {
		var buf [4]byte
		binary.LittleEndian.PutUint32(buf[:], uint32(cp))
		out.Write(buf[:])
	}

	// Bitmap data for each glyph
	for _, cp := range codepoints {
		bmp := renderGlyph(face, cp, glyphW, glyphH, ascent)
		// Convert to 1bpp packed
		packed := make([]byte, glyphSize)
		for y := 0; y < glyphH; y++ {
			for x := 0; x < glyphW; x++ {
				if bmp.GrayAt(x, y).Y > 127 {
					packed[y*bytesPerRow+x/8] |= 0x80 >> (x % 8)
				}
			}
		}
		out.Write(packed)
	}

	totalSize := 4 + len(codepoints)*4 + len(codepoints)*glyphSize
	fmt.Fprintf(os.Stderr, "Output: %s (%d bytes)\n", *outPath, totalSize)

	// Also print the chars for verification
	fmt.Fprintf(os.Stderr, "Chars: ")
	for _, cp := range codepoints {
		buf := make([]byte, 4)
		n := utf8.EncodeRune(buf, cp)
		os.Stderr.Write(buf[:n])
	}
	fmt.Fprintln(os.Stderr)
}

func renderGlyph(face font.Face, cp rune, w, h, ascent int) *image.Gray {
	img := image.NewGray(image.Rect(0, 0, w, h))
	draw.Draw(img, img.Bounds(), image.Black, image.Point{}, draw.Src)

	d := font.Drawer{
		Dst:  img,
		Src:  image.White,
		Face: face,
		Dot:  fixed.P(0, ascent),
	}
	d.DrawString(string(cp))
	return img
}
