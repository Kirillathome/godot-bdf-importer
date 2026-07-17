@tool
extends EditorImportPlugin


# the glyphlist.txt used to populate the glyphmap
const GLYPHLIST_PATH = "res://addons/bdf_importer/glyphlist.txt"
const ATLAS_BOUNDS = Vector2i(16, 16)

# postscript name to unicode
var glyphmap: Dictionary[String, int]

#region plugin shenanigans
func _get_importer_name() -> String:
	return "fnak.font.bdf.bitmap"


func _get_visible_name() -> String:
	return "Bitmap BDF Font Importer"


func _get_recognized_extensions() -> PackedStringArray:
	return ["bdf"]


func _get_save_extension() -> String:
	return "fontdata"


func _get_resource_type() -> String:
	return "FontFile"


func _get_import_options(_path: String, _preset_index: int) -> Array[Dictionary]:
	return []


func _get_preset_count() -> int:
	return 0


func _get_preset_name(_preset_index: int) -> String:
	return "Default"
#endregion


func _import(source_file: String, save_path: String, _options: Dictionary, _platform_variants: Array[String], _gen_files: Array[String]) -> Error:
	var file := FileAccess.open(source_file, FileAccess.READ)
	if !file:
		return FileAccess.get_open_error()
	
	populate_glyphmap()
	
	var bdf_font := BDFFont.new(file, glyphmap)
	var font := bdf_font.assemble_fontfile()

	#for page in font.get_texture_count(0, Vector2i(0, bdf_font.fixed_size)):
		#var filename := ".".join(["res://dump/" + source_file.get_file().trim_suffix(".bdf"), page, "png"])
		#font.get_texture_image(0, Vector2i(0, bdf_font.fixed_size), page).save_png(filename)
	
	return ResourceSaver.save(font, ".".join([save_path, _get_save_extension()]))


func populate_glyphmap() -> void:
	if !glyphmap.is_empty():
		print("(not repopulating glyphmap)")
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
	
	print("Sucessfully populated the glyphmap.")


class BDFFont extends RefCounted:
	var fixed_size: int
	var glyph_bounds: Vector2
	var glyph_offset: Vector2
	var font_family: String
	# BITMAP glyph distribution format
	# but actually, interestingly enough, glyphs are allowed to define their own bounding boxes
	# however, for the sake of simplicity and because of the lack of relevance (glyphs use the
	# same bounds as the font in terminus) I will assume that every glyhp is the same size.
	var font_style: int = TextServer.FONT_FIXED_WIDTH
	var font_weight: int = 400
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
				
				# FONTBOUNDINGBOX 8 16 0 -4
				"FONTBOUNDINGBOX":
					var split := line.trim_prefix("FONTBOUNDINGBOX ").split_floats(" ")
					glyph_bounds = Vector2(split[0], split[1])
					glyph_offset = Vector2(split[2], split[3])
				
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
	
	
	func parse_glyph(file: FileAccess, idx: int) -> void:
		glyphs[idx] = Glyph.new(file, glyphmap)
	
	
	func assemble_fontfile() -> FontFile:
		var font := FontFile.new()
		
		font.allow_system_fallback = false
		font.fixed_size = fixed_size
		#font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_INTEGER_ONLY
		font.fixed_size_scale_mode = TextServer.FIXED_SIZE_SCALE_ENABLED
		font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		font.subpixel_positioning = TextServer.SUBPIXEL_POSITIONING_DISABLED
		font.hinting = TextServer.HINTING_NONE
		
		font.set_cache_ascent(0, fixed_size, 12)
		font.set_cache_descent(0, fixed_size, 4)
		
		var page_size := ATLAS_BOUNDS.x * ATLAS_BOUNDS.y
		var bounds := Vector2i(glyph_bounds)
		var glyph_count := glyphs.size()
		
		for page in ceili(glyph_count / float(page_size)):
			var data: PackedByteArray
			# one byte per pixel
			data.resize(ATLAS_BOUNDS.x * bounds.x * ATLAS_BOUNDS.y * bounds.y)
			
			# either a full page or however many glyphs remain
			for glyph_idx in mini(page_size, glyph_count - page * page_size):
				var glyph := glyphs[page * page_size + glyph_idx]
				var glyph_row := floori(glyph_idx / float(ATLAS_BOUNDS.x))
				var glyph_column := glyph_idx % ATLAS_BOUNDS.x
				var fixed_vec := Vector2i(fixed_size, 0)
				
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
				
				#if page == 0:
					#print("glyph: ", char(glyph.unicode))
					#print("row, column: (%s, %s)" % [glyph_row, glyph_column])
				
				font.set_glyph_advance(0, fixed_size, glyph.unicode, Vector2(bounds.x, 0))
				font.set_glyph_offset(0, fixed_vec, glyph.unicode, glyph_offset)
				#font.set_glyph_offset(0, fixed_vec, glyph.unicode, Vector2(0, -0.5 * bounds.y))
				font.set_glyph_size(0, fixed_vec, glyph.unicode, glyph_bounds)
				font.set_glyph_uv_rect(0, fixed_vec, glyph.unicode, Rect2(
					glyph_column * bounds.x,
					glyph_row * bounds.y,
					glyph_bounds.x,
					glyph_bounds.y
				))
				font.set_glyph_texture_idx(0, fixed_vec, glyph.unicode, page)
				
				for row in bounds.y:
					#if page == 0 and glyph_idx == 16:
						#print("row ", row)
					for column in bounds.x:
						#if page == 0 and glyph_idx == 16:
							#print("column ", column)
							#print("COMBINED LOCATION: ", ((glyph_row * bounds.y) + row) * (ATLAS_BOUNDS.x * bounds.x) + glyph_column * bounds.x + column)
						data[
								((glyph_row * bounds.y) + row) * ATLAS_BOUNDS.x * bounds.x +
								glyph_column * bounds.x + column
						] = int(glyph.get_pixel(column, row)) * 0xff
			
			var image := Image.create_from_data(
					ATLAS_BOUNDS.x * bounds.x,
					ATLAS_BOUNDS.y * bounds.y,
					false,
					Image.FORMAT_L8,
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
