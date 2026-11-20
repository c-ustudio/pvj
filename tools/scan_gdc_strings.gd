extends SceneTree
## Headless: search the compiled scripts (.gdc) under a folder for strings.
## Exported .gdc files are zstd-compressed token buffers, so a byte grep of an
## APK never finds a string constant (it misses the OAuth secret even in the
## builds that shipped it). This decompresses each one first.
##
##   godot --headless --script tools/scan_gdc_strings.gd -- <dir> <needle>...
##
## Prints "HIT <file> <needle>" per match and "scan_gdc_strings: <n> files,
## <m> hits"; exits 1 when anything matched, 2 when nothing could be read.

func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	if args.size() < 2:
		print("usage: -- <dir> <needle>...")
		quit(2)
		return
	var needles: Array[String] = []
	for i in range(1, args.size()):
		needles.append(args[i].to_utf8_buffer().hex_encode())
	var files: Array[String] = []
	_collect(args[0], files)
	var hits := 0
	for path: String in files:
		var body := _decode(path)
		if body.is_empty():
			print("UNREADABLE %s" % path)
			continue
		var hex := body.hex_encode()
		for i in needles.size():
			if _find_aligned(hex, needles[i]):
				print("HIT %s %s" % [path, args[i + 1]])
				hits += 1
	print("scan_gdc_strings: %d files, %d hits" % [files.size(), hits])
	quit(2 if files.is_empty() else (1 if hits > 0 else 0))


func _collect(dir: String, out: Array[String]) -> void:
	for f: String in DirAccess.get_files_at(dir):
		if f.ends_with(".gdc"):
			out.append(dir.path_join(f))
	for d: String in DirAccess.get_directories_at(dir):
		_collect(dir.path_join(d), out)


## "GDSC", u32 version, u32 decompressed size (0 = stored), then the buffer.
func _decode(path: String) -> PackedByteArray:
	var raw := FileAccess.get_file_as_bytes(path)
	if raw.size() < 12 or raw.slice(0, 4).get_string_from_ascii() != "GDSC":
		return PackedByteArray()
	var size := raw.decode_u32(8)
	if size == 0:
		return raw.slice(12)
	return raw.slice(12).decompress(size, FileAccess.COMPRESSION_ZSTD)


## A byte match starts on an even hex index.
func _find_aligned(hex: String, needle: String) -> bool:
	var at := hex.find(needle)
	while at != -1:
		if at % 2 == 0:
			return true
		at = hex.find(needle, at + 1)
	return false
