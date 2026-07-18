#!/usr/bin/env python3
"""Generate Sheltie's layered Liquid Glass-inspired app icon renditions."""

from pathlib import Path
from PIL import Image, ImageChops, ImageDraw, ImageFilter

SIZE = 1024
SCALE = 2
CANVAS = SIZE * SCALE
OUTPUT = Path(__file__).resolve().parents[1] / "Sheltie/Resources/Assets.xcassets/AppIcon.appiconset"


def color(hex_value: str) -> tuple[int, int, int]:
    value = hex_value.removeprefix("#")
    return tuple(int(value[index:index + 2], 16) for index in (0, 2, 4))


def vertical_gradient(top: str, bottom: str) -> Image.Image:
    gradient = Image.new("RGB", (1, CANVAS))
    pixels = gradient.load()
    a, b = color(top), color(bottom)
    for y in range(CANVAS):
        amount = y / (CANVAS - 1)
        pixels[0, y] = tuple(round(a[channel] * (1 - amount) + b[channel] * amount) for channel in range(3))
    return gradient.resize((CANVAS, CANVAS))


def rounded_mask(box: tuple[int, int, int, int], radius: int) -> Image.Image:
    mask = Image.new("L", (CANVAS, CANVAS))
    ImageDraw.Draw(mask).rounded_rectangle(tuple(value * SCALE for value in box), radius=radius * SCALE, fill=255)
    return mask


def add_glow(image: Image.Image, center: tuple[int, int], radius: int, fill: str, opacity: int) -> None:
    layer = Image.new("RGBA", image.size)
    draw = ImageDraw.Draw(layer)
    x, y = (value * SCALE for value in center)
    r = radius * SCALE
    draw.ellipse((x - r, y - r, x + r, y + r), fill=(*color(fill), opacity))
    layer = layer.filter(ImageFilter.GaussianBlur(radius * SCALE * 0.55))
    image.alpha_composite(layer)


def add_glass_panel(image: Image.Image, dark: bool) -> None:
    box = (120, 112, 904, 912)
    mask = rounded_mask(box, 216)

    shadow = Image.new("RGBA", image.size)
    shadow_mask = mask.filter(ImageFilter.GaussianBlur(42 * SCALE))
    shadow.putalpha(shadow_mask.point(lambda value: value * 74 // 255))
    shadow.paste((17, 32, 87, 74), (0, 24 * SCALE), shadow)
    image.alpha_composite(shadow)

    backdrop = image.filter(ImageFilter.GaussianBlur(30 * SCALE))
    frost = Image.new("RGBA", image.size, (228, 237, 255, 58 if dark else 96))
    panel = Image.composite(backdrop, Image.new("RGBA", image.size), mask)
    image.alpha_composite(panel)
    frost.putalpha(mask.point(lambda value: value * (58 if dark else 96) // 255))
    image.alpha_composite(frost)

    outline = Image.new("RGBA", image.size)
    draw = ImageDraw.Draw(outline)
    scaled = tuple(value * SCALE for value in box)
    draw.rounded_rectangle(scaled, radius=216 * SCALE, outline=(255, 255, 255, 172), width=5 * SCALE)
    draw.arc(scaled, 198, 330, fill=(255, 255, 255, 220), width=8 * SCALE)
    image.alpha_composite(outline)


def add_glass_piece(
    image: Image.Image,
    box: tuple[int, int, int, int],
    radius: int,
    top: str,
    bottom: str,
    opacity: int,
    highlight: int = 185,
) -> None:
    mask = rounded_mask(box, radius)

    shadow = Image.new("RGBA", image.size, (20, 35, 95, 0))
    shadow_alpha = mask.filter(ImageFilter.GaussianBlur(18 * SCALE)).point(lambda value: value * 95 // 255)
    shadow.putalpha(shadow_alpha)
    shifted = Image.new("RGBA", image.size)
    shifted.alpha_composite(shadow, (0, 16 * SCALE))
    image.alpha_composite(shifted)

    fill = vertical_gradient(top, bottom).convert("RGBA")
    fill.putalpha(mask.point(lambda value: value * opacity // 255))
    image.alpha_composite(fill)

    sheen_mask = Image.new("L", image.size)
    draw = ImageDraw.Draw(sheen_mask)
    left, upper, right, lower = (value * SCALE for value in box)
    draw.rounded_rectangle((left + 7 * SCALE, upper + 7 * SCALE, right - 7 * SCALE, lower - 7 * SCALE), radius=max(1, (radius - 7) * SCALE), outline=highlight, width=5 * SCALE)
    sheen = Image.new("RGBA", image.size, (255, 255, 255, 0))
    sheen.putalpha(sheen_mask)
    image.alpha_composite(sheen)

    reflection = Image.new("RGBA", image.size)
    reflection_draw = ImageDraw.Draw(reflection)
    reflection_draw.rounded_rectangle(
        (left + 18 * SCALE, upper + 17 * SCALE, right - 18 * SCALE, upper + 42 * SCALE),
        radius=13 * SCALE,
        fill=(255, 255, 255, 76),
    )
    reflection.putalpha(ImageChops.multiply(reflection.getchannel("A"), mask))
    image.alpha_composite(reflection.filter(ImageFilter.GaussianBlur(3 * SCALE)))


def render(default: bool = True, tinted: bool = False) -> Image.Image:
    dark = not default and not tinted
    if tinted:
        base = vertical_gradient("#E8EBF0", "#9199A8").convert("RGBA")
        add_glow(base, (230, 190), 300, "#FFFFFF", 150)
        add_glow(base, (840, 820), 350, "#596273", 110)
    elif dark:
        base = vertical_gradient("#101A46", "#050A21").convert("RGBA")
        add_glow(base, (210, 170), 330, "#2E7DE9", 190)
        add_glow(base, (870, 760), 360, "#7A5AF8", 145)
        add_glow(base, (710, 170), 210, "#47D7C5", 70)
    else:
        base = vertical_gradient("#E8EEFF", "#AEBFEA").convert("RGBA")
        add_glow(base, (160, 120), 330, "#FFFFFF", 225)
        add_glow(base, (850, 790), 390, "#2E7DE9", 130)
        add_glow(base, (760, 160), 260, "#F52A65", 58)

    add_glass_panel(base, dark=dark)

    if tinted:
        side_top, side_bottom, center_top, center_bottom = "#4F596A", "#172033", "#FFFFFF", "#8892A4"
        side_opacity, center_opacity = 216, 230
    elif dark:
        side_top, side_bottom, center_top, center_bottom = "#A7C7FF", "#3559BC", "#E8F7FF", "#4BA9FF"
        side_opacity, center_opacity = 202, 235
    else:
        side_top, side_bottom, center_top, center_bottom = "#536CA8", "#172A67", "#9BE8FF", "#2E7DE9"
        side_opacity, center_opacity = 220, 244

    # The six pieces retain Sheltie's original abstract sheepdog face: ears/eyes,
    # a bright blaze, broad cheeks, and a centered muzzle.
    add_glass_piece(base, (258, 272, 424, 500), 55, side_top, side_bottom, side_opacity)
    add_glass_piece(base, (600, 272, 766, 500), 55, side_top, side_bottom, side_opacity)
    add_glass_piece(base, (442, 232, 582, 586), 62, center_top, center_bottom, center_opacity, 220)
    add_glass_piece(base, (258, 540, 390, 742), 49, side_top, side_bottom, side_opacity)
    add_glass_piece(base, (634, 540, 766, 742), 49, side_top, side_bottom, side_opacity)
    add_glass_piece(base, (414, 628, 610, 792), 58, side_top, side_bottom, side_opacity)

    return base.convert("RGB").resize((SIZE, SIZE), Image.Resampling.LANCZOS)


def main() -> None:
    OUTPUT.mkdir(parents=True, exist_ok=True)
    renditions = {
        "AppIcon.png": render(default=True),
        "AppIcon-Dark.png": render(default=False),
        "AppIcon-Tinted.png": render(tinted=True),
    }
    for filename, image in renditions.items():
        image.save(OUTPUT / filename, format="PNG", optimize=True)
        print(OUTPUT / filename)


if __name__ == "__main__":
    main()
