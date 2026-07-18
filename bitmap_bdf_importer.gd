@tool
extends EditorImportPlugin

# enum for presets, even though there only is the one
enum Preset {
	DEFAULT,
}

# the glyphlist.txt used to populate the glyphmap
const GLYPHLIST_PATH = "res://addons/bdf_importer/glyphlist.txt"

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
	return "fontdata"


func _get_resource_type() -> String:
	return "FontFile"


func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	var arr: Array[Dictionary]
	
	arr.push_back(_p_option(
		"use_alpha",
		true,
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


func _p_option(name: String, default_value: Variant, property_hint := PROPERTY_HINT_NONE, hint_string := "") -> Dictionary:
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
		return FileAccess.get_open_error()
	
	populate_glyphmap()
	
	var bdf_font := BDFFont.new(
			file,
			glyphmap,
			#options.get("override_font_family", ""),
			#options.get("override_font_style", 0b0),
			#options.get("override_weight", -1),
	)
	var font := bdf_font.assemble_fontfile(
			atlas_bounds,
			options.get("extra_advance", Vector2.ZERO),
			options.get("extra_offset", Vector2.ZERO),
			options.get("use_alpha", true),
	)
	
	if options.get("dump_pages", false):
		var fixed_vector := Vector2i(bdf_font.fixed_size, 0)
		for page in font.get_texture_count(0, fixed_vector):
			var filename := ".".join([
					source_file.trim_suffix(".bdf"),
					"page%d" % page,
					"png",
			])
			if font.get_texture_image(0, fixed_vector, page).save_png(filename) == OK:
				gen_files.push_back(filename)
	
	
	return ResourceSaver.save(font, ".".join([save_path, _get_save_extension()]))


func populate_glyphmap() -> void:
	if !glyphmap.is_empty():
		#print("(not repopulating glyphmap)")
		return
	
	var file := FileAccess.open(GLYPHLIST_PATH, FileAccess.READ)
	if !file:
		return
	
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
	
	#print("Sucessfully populated the glyphmap.")


class BDFFont extends RefCounted:
	var fixed_size: int
	var glyph_bounds: Vector2
	var glyph_offset: Vector2
	var font_family: String
	var font_style: int = 0b0
	var font_weight: int = 400
	
	var advance: float
	var ascent: float
	var descent: float
	
	#var advance: int
	var glyphs: Array[Glyph]
	var glyphmap: Dictionary[String, int]
	
	func _init(file: FileAccess, arg_glyphmap: Dictionary[String, int]) -> void:
		glyphmap = arg_glyphmap
		
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
					glyph_bounds = Vector2(split[0], split[1])
					glyph_offset = Vector2(split[2], split[3])
					
					advance = glyph_bounds.x # default advance value
				
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
				if prop.get_slice('"', 1) == "Bold":
					font_style |= TextServer.FONT_BOLD
					font_weight = 700
			
			# SLANT "R"
			"SLANT":
				if prop.get_slice('"', 1) == "I":
					font_style |= TextServer.FONT_ITALIC
			
			# FONT_ASCENT 12
			"FONT_ASCENT":
				ascent = prop.get_slice(" ", 1).to_float()
			
			# FONT_DESCENT 4
			"FONT_DESCENT":
				descent = prop.get_slice(" ", 1).to_float()
			
			# MIN_SPACE 8
			"MIN_SPACE":
				advance = prop.get_slice(" ", 1).to_float()
	
	
	func parse_glyph(file: FileAccess, idx: int) -> void:
		glyphs[idx] = Glyph.new(file, glyphmap)
	
	
	func assemble_fontfile(
			atlas_bounds: Vector2i,
			extra_advance: Vector2,
			extra_offset: Vector2,
			use_alpha: bool
	) -> FontFile:
		var font := FontFile.new()
		
		font.allow_system_fallback = false
		font.fixed_size = fixed_size
		font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
		#font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_ENABLED
		font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		font.hinting = TextServer.HINTING_NONE
		
		font.set_cache_ascent(0, fixed_size, ascent)
		font.set_cache_descent(0, fixed_size, descent)
		
		var page_size := atlas_bounds.x * atlas_bounds.y
		var bounds := Vector2i(glyph_bounds)
		var glyph_count := glyphs.size()
		
		for page in ceili(glyph_count / float(page_size)):
			var data: PackedByteArray
			
			# one byte if no transparency is used
			var bytes := atlas_bounds.x * bounds.x * atlas_bounds.y * bounds.y
			if use_alpha:
				# two bytes if it is
				bytes *= 2
			data.resize(bytes)
			
			# either a full page or however many glyphs remain
			for glyph_idx in mini(page_size, glyph_count - page * page_size):
				var glyph := glyphs[page * page_size + glyph_idx]
				var glyph_row := floori(glyph_idx / float(atlas_bounds.x))
				var glyph_column := glyph_idx % atlas_bounds.x
				var fixed_vec := Vector2i(fixed_size, 0)
				
				# (old debug code)
				#if glyph_idx == 0x30:
					#print(char(glyph.unicode))
					#print("BITMAP VERSION")
					#for b in glyph.bitmap:
						#print(String.num_int64(b, 2).pad_zeros(8))
					#print()
					#print("LOGIC VERSION")
					#for row in 16:
						#var s := ""
						#for column in 8:
							#s += "1" if glyph.get_pixel(column, row) else "0"
						#print(s)
					#print()
				
				font.set_glyph_advance(0, fixed_size, glyph.unicode, Vector2(advance, 0) + extra_advance)
				# funky offset shenanigans, was done this way in the official godot monospace importer
				font.set_glyph_offset(0, fixed_vec, glyph.unicode, Vector2(0, -0.5 * bounds.y) + glyph_offset + extra_offset)
				font.set_glyph_size(0, fixed_vec, glyph.unicode, glyph_bounds)
				font.set_glyph_uv_rect(0, fixed_vec, glyph.unicode, Rect2(
					glyph_column * bounds.x,
					glyph_row * bounds.y,
					glyph_bounds.x,
					glyph_bounds.y
				))
				font.set_glyph_texture_idx(0, fixed_vec, glyph.unicode, page)
				
				for row in bounds.y:
					for column in bounds.x:
						# pixel byte value
						var pixel := int(glyph.get_pixel(column, row)) * 0xff
						
						# index of the pixel in the byte array
						var loc := ((glyph_row * bounds.y) + row) * atlas_bounds.x * bounds.x +\
								glyph_column * bounds.x + column
						
						if use_alpha:
							loc *= 2
							data[loc+1] = pixel # alpha channel
						
						data[loc] = pixel # luminance channel
			
			var image := Image.create_from_data(
					atlas_bounds.x * bounds.x,
					atlas_bounds.y * bounds.y,
					false,
					Image.FORMAT_LA8 if use_alpha else Image.FORMAT_L8,
					data
			)
			
			#image.convert(Image.FORMAT_RGBAF)
			#print("image format: ", image.get_format())
			
			font.set_texture_image(0, Vector2i(fixed_size, 0), page, image)
			
		return font


class Glyph extends RefCounted:
	var unicode: int
	#var index: int # used for the atlas generation
	#var bitmap: BitMap
	
	var bounds: Vector2i
	var bitmap: PackedByteArray # access pixel information via helper methods
	var _byte_count: int # number of bytes per row
	
	func _init(file: FileAccess, glyphmap: Dictionary[String, int]) -> void:
		#index = idx
		
		# STARTCHAR a
		var chr := file.get_line().trim_prefix("STARTCHAR ")
		if chr == "char0":
			unicode = 0x0 # TEST: does godot accept this?
		elif glyphmap.has(chr):
			unicode = glyphmap[chr]
		elif chr.begins_with("uni"):
			unicode = chr.trim_prefix("uni").hex_to_int()
		else:
			unicode = 0xfffd
		
		while file.get_position() < file.get_length():
			var line := file.get_line()
			
			match line:
				"BITMAP":
					parse_bitmap(file)
				
				"ENDCHAR":
					break
				
				# BBX 8 16 0 -4
				_ when line.begins_with("BBX"):
					bounds = Vector2i(
						line.get_slice(" ", 1).to_int(),
						line.get_slice(" ", 2).to_int()
					)
					# bytes per row 
					_byte_count = ceili(bounds.x / 8.0)
					# bytes per row * row count
					bitmap.resize(_byte_count * bounds.y)
	
	
	func parse_bitmap(file: FileAccess) -> void:
		for row in bounds.y:
			var line := file.get_line()
			
			for column in _byte_count:
				bitmap[row * _byte_count + column] = line.substr(column * 2, 2).hex_to_int()
	
	
	func get_pixel(x: int, y: int) -> bool:
		var column := floori(x / 8.0)
		var byte := bitmap[y * _byte_count + column]
		#var byte := bitmap[y * _byte_count]
		
		return byte & (0b1 << (7 - (x % 8)))
		#return byte & 1 << (x % 8)
