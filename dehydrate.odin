/*

    Summary of algorithm:

    1.  Per channel, get the range of possible pixel values at a specific pixel
        over many sample images with the watermark.

    2.  Per pixel, enlarge ranges so their lengths are all the same.
        This is done because watermarks generally have only one alpha channel.

    3.  Remove the watermark on the target image by projecting these ranges
        back to 0..=255 (or whatever the bpp is).

*/
package dehydrate

import "core:fmt"
import "core:image/qoi"
import "core:image/png"
import "core:image"
import "core:bytes"
import "core:mem"

Range :: struct {
    from, to : f32,
}

range_increase :: proc(range : ^Maybe(Range), t : $T) {
    maximum :: 1 << (8 * size_of(T)) - 1

    f_low  :=  f32(t)      / (maximum + 1)
    f_high := (f32(t) + 1) / (maximum + 1)

    if r, ok := &range^.?; ok {
        r.from = min(r.from, f_low)
        r.to   = max(r.to,   f_high)
    } else {
        range^ = Range { f_low, f_high }
    }
}

ranges_normalize :: proc(ranges : []Range) {
    size : f32 = 0
    for range in ranges do if range.to - range.from > size do size = range.to - range.from
    for i in 0..<len(ranges) do range_set_size(&ranges[i], size)
}

range_set_size :: proc(range : ^Range, size : f32) {
    strength  := (range.to - range.from) / size
    range.from = strength * range.from
    range.to   = strength * range.to + (1 - strength)
}

range_map :: proc(range: Range, t : $T, offset: f32) -> T {
    maximum :: 1 << (8 * size_of(T)) - 1

    f := (f32(t) + offset) / (maximum + 1)

    return T((f - range.from) / (range.to - range.from) * maximum)
}

range_value :: proc(range: Range, $T : typeid) -> T {
    maximum :: 1 << (8 * size_of(T)) - 1

    if 1 - range.to + range.from == 0 do return 0

    return T((range.from) / (1 - range.to + range.from) * maximum)
}

range_power :: proc(range: Range, $T : typeid) -> T {
    maximum :: 1 << (8 * size_of(T)) - 1

    return T((1 - range.to + range.from) * maximum)
}

calculate_ranges :: proc(images : []^image.Image, width, height : int, $channels : int) -> []Range {
    buffers := make([][]byte, len(images))
    for image, idx in images do buffers[idx] = bytes.buffer_to_bytes(&image.pixels)

    output := make([]Range, width * height * channels)

    for y in 0..<height {
        for x in 0..<width {
            ranges : [channels]Maybe(Range)

            for image, idx in images {
                if x >= image.width || y >= image.height do continue

                i := (x + y * image.width) * image.channels

                switch image.depth {
                    case 8:
                        for c in 0..<channels {
                            range_increase(&ranges[c], buffers[idx][i + c])
                        }
                    case 16:
                        buf := mem.slice_data_cast([]u16, buffers[idx])
                        for c in 0..<channels {
                            range_increase(&ranges[c], buf[i + c])
                        }
                    case:
                        panic("Unknown depth encounterd")
                }
            }

            idx := (x + y * width) * channels

            for c in 0..<channels {
                output[idx + c] = ranges[c].? or_else { 0, 1 }
            }

            ranges_normalize(output[idx:idx+channels])
        }
    }

    delete(buffers)
    return output
}

test :: proc() -> image.Error {
    black_watermarked := image.load("black_watermarked.png") or_return
    white_watermarked := image.load("white_watermarked.png") or_return

    ranges := calculate_ranges({ black_watermarked, white_watermarked }, 256, 256, 3)

    watermark_calculated := new(image.Image)
    watermark_calculated.width      = black_watermarked.width
    watermark_calculated.height     = black_watermarked.height
    watermark_calculated.channels   = 4
    watermark_calculated.depth      = 8
    watermark_calculated.pixels     = bytes.Buffer{}
    watermark_calculated.background = nil
    resize(&watermark_calculated.pixels.buf, image.compute_buffer_size(
        watermark_calculated.width,
        watermark_calculated.height,
        4, 8,
    ))

    pixels := bytes.buffer_to_bytes(&watermark_calculated.pixels)
    for i in 0..<256*256 {
        pixels[i * 4 + 0] = range_value(ranges[i * 3 + 0], byte)
        pixels[i * 4 + 1] = range_value(ranges[i * 3 + 1], byte)
        pixels[i * 4 + 2] = range_value(ranges[i * 3 + 2], byte)
        pixels[i * 4 + 3] = range_power(ranges[i * 3 + 0], byte)
    }

    qoi.save_to_file("watermark_calculated.qoi", watermark_calculated)

    dehydrated := new(image.Image)
    dehydrated.width      = black_watermarked.width
    dehydrated.height     = black_watermarked.height
    dehydrated.channels   = 3
    dehydrated.depth      = 8
    dehydrated.pixels     = bytes.Buffer{}
    dehydrated.background = nil
    resize(&dehydrated.pixels.buf, image.compute_buffer_size(
        dehydrated.width,
        dehydrated.height,
        3, 8,
    ))

    pixels2 := bytes.buffer_to_bytes(&dehydrated.pixels)
    pixels3 := bytes.buffer_to_bytes(&black_watermarked.pixels)
    for i in 0..<256*256 {
        pixels2[i * 3 + 0] = range_map(ranges[i * 3 + 0], pixels3[i * black_watermarked.channels + 0], 0.5)
        pixels2[i * 3 + 1] = range_map(ranges[i * 3 + 1], pixels3[i * black_watermarked.channels + 1], 0.5)
        pixels2[i * 3 + 2] = range_map(ranges[i * 3 + 2], pixels3[i * black_watermarked.channels + 2], 0.5)
    }

    qoi.save_to_file("watermark_calculated.qoi", watermark_calculated) or_return
    qoi.save_to_file("dehydrated.qoi", dehydrated) or_return

    free(watermark_calculated)
    free(dehydrated)

    free(black_watermarked)
    free(white_watermarked)

    delete(ranges)
    return nil
}

main :: proc() {
    fmt.println(test())
}
