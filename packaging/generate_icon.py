#!/usr/bin/env python3
"""Generate AppIcon.icns from the microphone emoji using AppKit for proper emoji rendering."""
import subprocess
import shutil
from pathlib import Path


def create_emoji_png(emoji: str, size: int, output_path: Path):
    """Render an emoji to a PNG using AppKit (handles emoji properly on macOS)."""
    from AppKit import (
        NSImage, NSGraphicsContext, NSColor, NSString, NSFont,
        NSMutableParagraphStyle, NSAttributedString,
    )
    from Foundation import NSDictionary, NSMakeRect, NSZeroRect

    # Create an NSImage at the required size
    img = NSImage.alloc().initWithSize_((size, size))
    img.lockFocus()

    # Clear with transparent background
    NSColor.clearColor().set()
    from AppKit import NSRectFill, NSMakeRect
    NSRectFill(NSMakeRect(0, 0, size, size))

    # Draw the emoji string
    font_size = size * 0.80
    font = NSFont.systemFontOfSize_(font_size)
    attrs = NSDictionary.dictionaryWithObjectsAndKeys_(
        font, "NSFont",
    )
    ns_str = NSAttributedString.alloc().initWithString_attributes_(emoji, attrs)

    # Get natural size of the rendered string
    natural_size = ns_str.size()

    # Center the emoji in the canvas
    x = (size - natural_size.width) / 2
    y = (size - natural_size.height) / 2

    ns_str.drawAtPoint_((x, y))
    img.unlockFocus()

    # Export as PNG using NSBitmapImageRep
    from AppKit import NSBitmapImageRep, NSPNGFileType
    tiff_data = img.TIFFRepresentation()
    bitmap = NSBitmapImageRep.imageRepWithData_(tiff_data)
    png_data = bitmap.representationUsingType_properties_(NSPNGFileType, None)
    png_data.writeToFile_atomically_(str(output_path), True)


def create_app_icon(output_path: Path):
    iconset_dir = Path("/tmp/AppIcon.iconset")
    iconset_dir.mkdir(exist_ok=True)

    emoji = "🎙"

    sizes = [
        (16, "16x16"),
        (32, "16x16@2x"),
        (32, "32x32"),
        (64, "32x32@2x"),
        (128, "128x128"),
        (256, "128x128@2x"),
        (256, "256x256"),
        (512, "256x256@2x"),
        (512, "512x512"),
        (1024, "512x512@2x"),
    ]

    for size, name in sizes:
        png_path = iconset_dir / f"icon_{name}.png"
        create_emoji_png(emoji, size, png_path)
        print(f"  {size}x{size} → {png_path.name}")

    result = subprocess.run(
        ['iconutil', '-c', 'icns', str(iconset_dir), '-o', str(output_path)],
        capture_output=True, text=True
    )
    if result.returncode != 0:
        raise RuntimeError(f"iconutil failed: {result.stderr}")

    shutil.rmtree(iconset_dir)
    print(f"Generated: {output_path}")


if __name__ == '__main__':
    output = Path(__file__).parent / 'AppIcon.icns'
    print("Generating AppIcon.icns with microphone emoji...")
    create_app_icon(output)
