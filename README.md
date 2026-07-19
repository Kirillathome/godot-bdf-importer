# godot-bdf-importer

A simple Godot plugin to import various fonts with the `.bdf` (Glyph **B**itmap **D**istribution **F**ormat) extension. Use this plugin if converting `.bdf` fonts to *TrueType* fonts, just for Godot to convert them back to bitmaps hurts your soul as much as mine.

## Features

When importing a font, the following settings are available in the import menu:
- `use_alpha` *(bool)*: by default, the bitmaps are converted to `FORMAT_LA8` images, meaning there is a channel both for *luminance* (monochrome color) and *alpha*. Turning this setting off creates `FORMAT_L8` images instead, saving a color channel but resulting in every glyph having a black backround. Turn this off if you don't need transparency and/or really care about your kilobytes of memory.
- `scale_fractional` *(bool)*: off by default, to only allow for integer scaling of the font. Turning this on will remove that restriction, but remember that scaling pixel art will not yield good results!
- `atlas_bounds` *(Vector2i)*: texture size (in glyphs) for the *pages* of the font. The default value of **Vector2i(16, 16)** with a **8x16** font would result in a page size of **128x256**px^2. No component may be zero or negative. Feel free to adjust this, just remember to keep it at a sane value.
- `extra_advance` *(Vector2)*: additional advance to be added to glyphs, for in-/decreasing the distance between them. The *x* component may negative, but the total advance value will never be lower than **0**. The *y* component does not seem to do anything, but you can still adjust it :).
- `extra_offset` *(Vector2)*: additional offset to add to every glyph, resulting in a font offset by this value. Useful to slighlty nudge the font in a direction to make it look better.
- `underline_position` *(float)*: override or set the position of the underline. Keeping this at **0.0** will use either the one specified by the font, or leave it unset. Note that positive values will move the underline up instead of down, the reverse of the behaviour in Godot (to keep it consitent with the way this works in `.bdf` fonts).
- `underline_thickness` *(float)*: override or set the thickness of the underline. **0.0** works the same way as above.
- `dump_pages` *(bool)*: dump the generated pages as `.png` files in the same directory as the font, for debugging, aesthetic, or any purposes really.

## Notes

Please note that I whipped up this plugin myself within a couple of days *without* knowing that much about the `.bdf` format, nor about the inner workings of the Godot *FontFile* in general, so while it does work in my testing, issues may arise when using fonts that I didn't test. If you find a font that doesn't work, feel free to open an issue or a pull request. If you find any other issue, know an improvement, or are simply better than me, feel free to contibute!

Also some general notes:
- Remember to set the `texture_filter` on either just your labels or project-wide to `nearest`, or else the font will look very blurry!
- `glyphlist.txt` uses the **BSD 3 Clause License**. This shouldn't cause any issues, since that is quite a permissive license, and also Godot does not keep `.txt` files in exported projects by default. Just keep this in mind if you choose to reuse that file somewhere else.
- There is a chance that my glyph offsetting logic is still wrong, as I pretty much freestyled it untli it looked correct. Also, fonts that specify a `METRICSSET` that is non-zero will probably not display correctly, but that shouldn't be a problem for *most* fonts.

**Have fun!**