@tool
extends EditorImportPlugin

# enum for presets, even though there only is the one
enum Preset {
	DEFAULT,
}

# the glyphlist.txt used to populate the glyphmap
const GLYPHLIST_PATH = "res://addons/godot-bdf-importer/glyphlist.txt"

# postscript name to unicode code map
var glyphmap: Dictionary[String, int]


#region plugin shenanigans
func _get_importer_name() -> String:
	return "fnak.font.bdf.bitmap"


func _get_visible_name() -> String:
	return "BDF Font Importer"


func _get_recognized_extensions() -> PackedStringArray:
	return ["bdf"]


func _get_save_extension() -> String:
	return "fontdata" # pretty sure that's the godot extension for fonts


func _get_resource_type() -> String:
	return "FontFile"


func _get_import_options(_path: String, preset_index: int) -> Array[Dictionary]:
	var arr: Array[Dictionary]
	
	match preset_index:
		Preset.DEFAULT:
			arr.push_back(_p_option(
				"use_alpha",
				true,
			))
			
			arr.push_back(_p_option(
				"scale_fractional",
				false,
			))
			
			arr.push_back(_p_option(
				"atlas_bounds",
				Vector2i(16, 16),
				PROPERTY_HINT_LINK,
			))
			
			arr.push_back(_p_option(
				"extra_advance",
				Vector2.ZERO,
			))
			
			arr.push_back(_p_option(
				"extra_offset",
				Vector2.ZERO,
			))
			
			arr.push_back(_p_option(
				"underline_position",
				0.0,
			))
			
			arr.push_back(_p_option(
				"underline_thickness",
				0.0,
			))
			
			arr.push_back(_p_option(
				"dump_pages",
				false,
			))
			
			#arr.push_back(_p_option(
				#"override_font_family",
				#"",
			#))
			#arr.push_back(_p_option(
				#"override_weight",
				#-1,
				#PROPERTY_HINT_RANGE,
				#"100,999,1,or_less,prefer_slider"
			#))
			#arr.push_back(_p_option(
				#"override_font_style",
				#0b0,
				#PROPERTY_HINT_FLAGS,
				#"Bold:1,Italic:2,Fixed Width:4"
			#))
	
	return arr


# small helper method
func _p_option(
		name: String,
		default_value: Variant,
		property_hint := PROPERTY_HINT_NONE,
		hint_string := "") -> Dictionary:
	var dict: Dictionary = {
		"name": name,
		"default_value": default_value,
	}
	
	if property_hint != PROPERTY_HINT_NONE:
		dict["property_hint"] = property_hint
		if !hint_string.is_empty():
			dict["hint_string"] = hint_string
	
	return dict


func _get_preset_count() -> int:
	return Preset.size()


func _get_preset_name(preset_index: int) -> String:
	match preset_index:
		Preset.DEFAULT:
			return "Default"
		_:
			return "I dunno man"
#endregion


func _import(source_file: String, save_path: String, options: Dictionary, _platform_variants: Array[String], gen_files: Array[String]) -> Error:
	var atlas_bounds: Vector2i = options.get("atlas_bounds", Vector2i(16, 16))
	if atlas_bounds.x < 1 or atlas_bounds.y < 1:
		push_error("Atlas size is zero or negative.")
		return FAILED
	
	var file := FileAccess.open(source_file, FileAccess.READ)
	if !file:
		return FileAccess.get_open_error() # couldn't open file
	
	# read glyphlist.txt and fill the map from it (if needed)
	var err := populate_glyphmap()
	if err:
		return err
	
	# parse the .bdf
	var bdf_font := BDFFont.new(
			file,
			glyphmap,
			options.get("underline_position", 0.0),
			options.get("underline_thickness", 0.0),
			#options.get("override_font_family", ""),
			#options.get("override_font_style", 0b0),
			#options.get("override_weight", -1),
	)
	# create a godot fontfile from it
	var font := bdf_font.assemble_fontfile(
			atlas_bounds,
			options.get("extra_advance", Vector2.ZERO),
			options.get("extra_offset", Vector2.ZERO),
			options.get("use_alpha", true),
			options.get("scale_fractional", false),
	)
	
	# dump pages if needed
	if options.get("dump_pages", false):
		var fixed_vector := Vector2i(bdf_font.fixed_size, 0)
		for page in font.get_texture_count(0, fixed_vector):
			var filename := ".".join([
					source_file.trim_suffix(".bdf"),
					"page%d" % page,
					"png",
			])
			if font.get_texture_image(0, fixed_vector, page).save_png(filename) == OK:
				# not sure if this is needed, but adds the pages to the gen_files array
				# feel free to comment out these lines if they break something
				gen_files.push_back(filename)
	
	# finally save the fontfile
	return ResourceSaver.save(font, ".".join([save_path, _get_save_extension()]))


func populate_glyphmap() -> Error:
	if !glyphmap.is_empty():
		return OK # no need to repopulate
	
	var file := FileAccess.open(GLYPHLIST_PATH, FileAccess.READ)
	if !file:
		push_error("Failed to read glyphlist.txt!")
		return FileAccess.get_open_error() # couldn't open file
	
	while file.get_position() < file.get_length():
		var line := file.get_line()
		if line.is_empty() or line[0] == "#":
			continue
		
		var split := line.strip_edges().split(";", false, 2)
		if split[1].contains(" "):
			# there are certain glyphs like "tchehmeeminitialarabic" defined, where multiple unicode
			# endpoints are given separated by spaces, which I assume is a character sequence
			
			# since I am using this for font parsing, no clue how this is supposed to help me
			# meaning I just ignore this
			continue
			
		glyphmap[split[0]] = split[1].hex_to_int()
	
	return OK # done


#region helper subclasses
class BDFFont extends RefCounted:
	var fixed_size: int
	var max_glyph_bounds: Vector2
	var default_glyph_offset: Vector2
	var font_family: String
	var font_style: int = TextServer.FONT_FIXED_WIDTH # is unset automatically if it isn't
	var font_weight: int = 400 # ...is this used for bitmap fonts?
	
	var advance: Vector2 # either set in properties or glyph BBX is used as fallback
	var ascent: float
	var descent: float
	var underline_position: float
	var underline_thickness: float
	
	var glyphs: Array[Glyph]
	var glyphmap: Dictionary[String, int]
	
	func _init(
			file: FileAccess,
			arg_glyphmap: Dictionary[String, int],
			underline_pos: float,
			underline_thick: float) -> void:
		glyphmap = arg_glyphmap
		underline_position = underline_pos
		underline_thickness = underline_thick
		
		while file.get_position() < file.get_length():
			var line := file.get_line()
			var key := line.get_slice(" ", 0)
			
			match key:
				# SIZE 16 72 72 (I do not need the resolution)
				"SIZE":
					fixed_size = line.get_slice(" ", 1).to_int()
					
					# default ascent/descent values
					ascent = fixed_size * 0.5
					descent = ascent
				
				# FONTBOUNDINGBOX 8 16 0 -4
				"FONTBOUNDINGBOX":
					var split := line.trim_prefix("FONTBOUNDINGBOX ").split_floats(" ")
					max_glyph_bounds = Vector2(split[0], split[1])
					default_glyph_offset = Vector2(split[2], split[3])
					
					#advance = max_glyph_bounds.x # default advance value
				
				# I'll just trust the document on this
				"DWIDTH", "DWIDTH1":
					var split := line.trim_prefix("DWIDTH ").trim_prefix("DWIDTH1 ").split_floats(" ")
					advance = Vector2(split[0], split[1])
				
				# STARTPROPERTIES 20
				"STARTPROPERTIES":
					for i in line.get_slice(" ", 1).to_int():
						parse_property(file.get_line())
					
					# ENDPROPERTIES (will now be discarded.)
					file.get_line()
				
				# CHARS 1356
				"CHARS":
					# what could POSSIBLY go wrong...?
					var count := line.get_slice(" ", 1).to_int()
					glyphs.resize(count)
					for i in count:
						parse_glyph(file, i)
	
	
	func parse_property(prop: String) -> void:
		# not sure if this is faster than begins_with(), looks better though
		var key := prop.get_slice(" ", 0)
		
		match key:
			# FAMILY_NAME "Terminus"
			"FAMILY_NAME":
				# using quotes as a delimiter to slightly reduce code amount
				font_family = prop.get_slice('"', 1)
			
			# WEIGHT_NAME "Medium"
			"WEIGHT_NAME":
				if prop.get_slice('"', 1).to_lower() == "bold":
					font_style |= TextServer.FONT_BOLD
					font_weight = 700
			
			# SLANT "R"
			"SLANT":
				if prop.get_slice('"', 1).to_lower() == "i":
					font_style |= TextServer.FONT_ITALIC
			
			# FONT_ASCENT 12
			"FONT_ASCENT":
				ascent = prop.get_slice(" ", 1).to_float()
			
			# FONT_DESCENT 4
			"FONT_DESCENT":
				descent = prop.get_slice(" ", 1).to_float()
			
			# UNDERLINE_POSITION -1 (TEST: does this move the outline up or down?)
			"UNDERLINE_POSITION" when underline_position == 0.0:
				underline_position = prop.get_slice(" ", 1).to_float()
			
			# UNDERLINE_THICKNESS 1
			"UNDERLINE_THICKNESS" when underline_thickness == 0.0:
				underline_thickness = prop.get_slice(" ", 1).to_float()
	
	
	func parse_glyph(file: FileAccess, idx: int) -> void:
		glyphs[idx] = Glyph.new(file, glyphmap)
	
	
	func assemble_fontfile(
			atlas_bounds: Vector2i,
			extra_advance: Vector2,
			extra_offset: Vector2,
			use_alpha: bool,
			scale_fractional: bool) -> FontFile:
		# create godot fontfile
		var font := FontFile.new()
		
		# set font settings to be similar to the ones used in the official importer
		font.allow_system_fallback = false
		font.fixed_size = fixed_size
		font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_ENABLED if scale_fractional\
				else TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
		font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		font.hinting = TextServer.HINTING_NONE
		font.set_cache_ascent(0, fixed_size, ascent)
		font.set_cache_descent(0, fixed_size, descent)
		if underline_position != 0.0:
			font.set_cache_underline_position(0, fixed_size, -underline_position)
		if underline_thickness != 0.0:
			font.set_cache_underline_thickness(0, fixed_size, underline_thickness)
		
		var page_size := atlas_bounds.x * atlas_bounds.y
		var fbounds := Vector2i(max_glyph_bounds)
		var glyph_count := glyphs.size()
		
		for page in ceili(glyph_count / float(page_size)):
			var data: PackedByteArray # image data
			
			# one byte if no transparency is used
			var bytes := atlas_bounds.x * fbounds.x * atlas_bounds.y * fbounds.y
			if use_alpha:
				# two bytes if it is
				bytes *= 2
			data.resize(bytes)
			
			# either a full page or however many glyphs remain
			for glyph_idx in mini(page_size, glyph_count - page * page_size):
				var glyph := glyphs[page * page_size + glyph_idx]
				if !glyph.is_valid(max_glyph_bounds):
					push_warning("Skipping invalid glyph. (page %d, idx %d)" % [page, glyph_idx])
					continue # skip glyph if it isn't valid
				
				var glyph_row := floori(glyph_idx / float(atlas_bounds.x))
				var glyph_column := glyph_idx % atlas_bounds.x
				var fixed_vec := Vector2i(fixed_size, 0) # yes, this is the correct way around (for whatever reason)
				var bounds := glyph.bounds
				var adv := extra_advance
				
				if glyph.advance: # if DWIDTH if specified
					adv += glyph.advance
				elif advance: # use the font level DWIDTH if specified
					adv += advance
				else: # everything is bad
					adv += Vector2(bounds.x + glyph.offset.x, 0.0)
				adv = adv.maxf(0.0) # advance may not be negative
				
				# unset monospace flag if needed
				font_style &= ~(int(bounds.x != max_glyph_bounds.x) << 2)
				
				font.set_glyph_advance(0, fixed_size, glyph.unicode, adv)
			 	# this one took a while
				# while I'm still not sure if I handle the offsets 100% correctly, they can quite
				# easily be adjusted using the import settings, meaning that this shouldn't be
				# fatal if I got it wrong
				font.set_glyph_offset(0, fixed_vec, glyph.unicode,
						Vector2(0, max_glyph_bounds.y - bounds.y - ascent)\
						+ Vector2(
								glyph.offset.x - default_glyph_offset.x,
								default_glyph_offset.y - glyph.offset.y
						)\
						+ extra_offset
				)
				font.set_glyph_size(0, fixed_vec, glyph.unicode, bounds)
				font.set_glyph_uv_rect(0, fixed_vec, glyph.unicode, Rect2(
					glyph_column * fbounds.x,
					glyph_row * fbounds.y,
					bounds.x,
					bounds.y
				))
				font.set_glyph_texture_idx(0, fixed_vec, glyph.unicode, page)
				
				for row in bounds.y:
					for column in bounds.x:
						# pixel byte value
						var pixel := int(glyph.get_pixel(column, row)) * 0xff
						
						# index of the pixel in the byte array
						var loc := ((glyph_row * fbounds.y) + row) * atlas_bounds.x * fbounds.x +\
								glyph_column * fbounds.x + column
						
						if use_alpha:
							loc *= 2
							data[loc+1] = pixel # alpha channel
						
						data[loc] = pixel # luminance channel
			
			# finally create the image
			var image := Image.create_from_data(
					atlas_bounds.x * fbounds.x,
					atlas_bounds.y * fbounds.y,
					false,
					Image.FORMAT_LA8 if use_alpha else Image.FORMAT_L8,
					data
			)
			
			font.set_texture_image(0, Vector2i(fixed_size, 0), page, image)
		
		# set some remaining font flags
		font.font_name = font_family
		font.font_style = font_style
		font.font_weight = font_weight
		return font


class Glyph extends RefCounted:
	var unicode: int
	var bounds: Vector2i
	var offset: Vector2
	var advance: Vector2
	var bitmap: PackedByteArray # bitmap flattened into a one-dimensional byte array
	
	var _byte_count: int # number of bytes per row
	var _valid := true
	
	func _init(file: FileAccess, glyphmap: Dictionary[String, int]) -> void:
		# STARTCHAR a
		var chr := file.get_line().trim_prefix("STARTCHAR ")
		if chr == "char0": # hardcoded null character
			unicode = 0x0
		elif glyphmap.has(chr):
			unicode = glyphmap[chr]
		elif chr.begins_with("uni"):
			unicode = chr.trim_prefix("uni").hex_to_int()
			if !unicode:
				_return_from_error(file, chr)
				return
		elif chr.begins_with("char"):
			# I assume that this is the correct way to interpret the char prefix
			unicode = chr.trim_prefix("char").to_int()
			if !unicode:
				_return_from_error(file, chr)
				return
		else:
			_return_from_error(file, chr)
			return
		
		while file.get_position() < file.get_length():
			var line := file.get_line()
			
			match line:
				"BITMAP":
					parse_bitmap(file)
				
				"ENDCHAR":
					break # done
				
				# BBX 8 16 0 -4
				_ when line.begins_with("BBX"):
					var split := line.trim_prefix("BBX ").split_floats(" ")
					bounds = Vector2i(int(split[0]), int(split[1]))
					offset = Vector2(split[2], split[3])
					
					# bytes per row 
					_byte_count = ceili(bounds.x / 8.0)
					# bytes per row * row count
					bitmap.resize(_byte_count * bounds.y)
				
				# DWIDTH 8 0
				_ when line.begins_with("DWIDTH"):
					var split := line.trim_prefix("DWIDTH ").trim_prefix("DWIDTH1 ").split_floats(" ")
					advance = Vector2(split[0], split[1])
	
	
	func _return_from_error(file: FileAccess, chr: String) -> void:
		push_error("Failed to parse glyph '", chr, "', skipping...")
		_valid = false
		
		while file.get_position() < file.get_length():
			var line := file.get_line()
			if line == "ENDCHAR":
				break
	
	
	func parse_bitmap(file: FileAccess) -> void:
		for row in bounds.y:
			var line := file.get_line()
			
			for column in _byte_count:
				bitmap[row * _byte_count + column] = line.substr(column * 2, 2).hex_to_int()
	
	
	func get_pixel(x: int, y: int) -> bool:
		var column := floori(x / 8.0)
		var byte := bitmap[y * _byte_count + column]
		
		# read bits from left to right
		return byte & (0b1 << (7 - (x % 8)))
	
	
	func is_valid(max_bounds: Vector2) -> bool:
		# check if glyph is valid and fits into the FONTBOUNDINGBOX
		return _valid and bounds.x <= max_bounds.x and bounds.y <= max_bounds.y
#endregion
