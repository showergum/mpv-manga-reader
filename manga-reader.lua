require "mp.options"
local utils = require "mp.utils"
local ext = {".avif", ".bmp", ".gif", ".jpg", ".jpeg", ".png", ".tif", ".tiff", ".webp"}
local first_start = true
local filedims = {}
local initiated = false
local input = ""
local jump = false
local opts = {
	auto_start = false,
	continuous = false,
	continuous_size = 8,
	double = false,
	manga = true,
	monitor_height = 1080,
	monitor_width = 1920,
	pan_size = 0.05,
	skip_size = 10,
	trigger_zone = 0.05,
}
local valid_width = {}
local valid_height = {}

function calculate_zoom_level(dims, pages)
	dims[0] = tonumber(dims[0])
	dims[1] = tonumber(dims[1]) * opts.continuous_size
	local scaled_width = opts.monitor_height/dims[1] * dims[0]
	if opts.monitor_width >= opts.continuous_size*scaled_width then
		return pages
	else
		return opts.monitor_width / scaled_width
	end
end

function check_images()
	local audio = mp.get_property("audio-params")
	local frame_count = mp.get_property_number("estimated-frame-count")
	local length = mp.get_property_number("playlist-count")
	if audio == nil and (frame_count == 1 or frame_count == 0) and length > 1 then
		return true
	else
		return false
	end
end

function check_heights(index)
	if filedims[index][1] == filedims[index+1][1] then
		return 0
	elseif math.abs(filedims[index][1] - filedims[index+1][1]) < 20 then
		return 1
	else
		return 2
	end
end

function change_page(amount)
	local old_index = mp.get_property_number("playlist-pos")
	local len = mp.get_property_number("playlist-count")
	local index = old_index + amount
	if index < 0 then
		index = 0
	end
	if index > len - 2 and opts.double then
		index = len - 2
	elseif index > len - 2 then
		index = len - 1
	end
	mp.set_property("lavfi-complex", "")
	mp.set_property("playlist-pos", index)
	if opts.continuous and initiated then
		local pages
		if opts.continuous_size + index > len then
			pages = opts.continuous_size + index - len
		else
			pages = opts.continuous_size
		end
		if amount >= 0 then
			continuous_page("top", pages)
		elseif old_index == 0 and amount < 0 then
			continuous_page("top", pages)
		elseif amount < 0 then
			continuous_page("bottom", pages)
		end
	end
	if opts.double and initiated then
		ret = check_heights(index)
		if ret == 0 then
			double_page(false)
		elseif ret == 1 then
			double_page(true)
		end
	end
end

function continuous_page(alignment, pages)
	local index = mp.get_property_number("playlist-pos")
	local len = mp.get_property_number("playlist-count")
	for i=index+1,index+pages-1 do
		local new_page = mp.get_property("playlist/"..tostring(i).."/filename")
		local success = mp.commandv("video-add", new_page, "auto")
		while not success do
			-- can fail on occasion so just retry until it works
			success = mp.commandv("video-add", new_page, "auto")
		end
	end
	local internal
	for i=0,pages-1 do
		if not mp.get_property_bool("track-list/"..tostring(i).."/external") then
			internal = i
		end
	end
	local arg = "[vid"..tostring(internal+1).."]"
	for i=0,pages-1 do
		if i ~= internal then
			arg = arg.." [vid"..tostring(i+1).."]"
		end
	end
	if pages > 4 then
		set_lavfi_complex_continuous(arg, alignment, pages)
	else
		set_lavfi_complex_continuous_simple(arg, alignment, pages)
	end
end

function double_page(scale)
	local index = mp.get_property_number("playlist-pos")
	local second_page = mp.get_property("playlist/"..tostring(index+1).."/filename")
	local success = mp.commandv("video-add", second_page, "auto")
	while not success do
		-- can fail on occasion so just retry until it works
		success = mp.commandv("video-add", second_page, "auto")
	end
	set_lavfi_complex_double(scale)
end

function log2(num)
	return math.log(num)/math.log(2)
end

function check_lavfi_complex(event)
	if event['error'] then
		mp.set_property("lavfi-complex", "")
		if opts.continuous then
			change_page(1)
		end
		if opts.double then
			local index = mp.get_property_number("playlist-pos")
			change_page(-1)
		end
	end
end

function set_lavfi_complex_continuous(arg, alignment, pages)
	local final
	local even
	if pages % 2 == 0 then
		final = pages - 1
		even = true
	else
		final = pages - 2
		even = false
	end
	local vstack = ""
	local split = str_split(arg, " ")
	local total_t = pages - 2
	local t_arr = {}
	for i=0,total_t-1 do
		t_arr[i] = "[t"..tostring(i+1).."]"
	end
	local t_index = 0
	local t_final = {}
	for i=0,final,2 do
		vstack = vstack..split[i].." "..split[i+1].." vstack "..t_arr[t_index].." ; "
		t_index = t_index + 1
		if (i + 2) % 4 == 0 then
			vstack = vstack..t_arr[t_index - 2].." "..t_arr[t_index - 1].." vstack "..t_arr[t_index].." ; "
			if i+2 ~= pages then
				if t_final[0] ~= nil then
					vstack = vstack..t_final[0].." "..t_arr[t_index].." vstack "..t_arr[t_index+1].." ; "
					t_index = t_index + 1
				end
				t_final[0] = t_arr[t_index]
			else
				t_final[1] = t_arr[t_index]
			end
			t_index = t_index + 1
		end
	end
	if t_final[1] == nil then
		t_final[1] = t_arr[total_t-1]
	end
	if even then
		vstack = vstack..t_final[0].." "..t_final[1].. " vstack [vo]"
	elseif (pages - 1) % 4 == 0 then
		vstack = vstack..t_arr[t_index-1].." "..split[pages - 1].." vstack [vo]"
	else
		vstack = vstack..t_arr[t_index - 2].." "..t_arr[t_index - 1].." vstack "..t_arr[t_index].." ; "
		vstack = vstack..t_arr[t_index].." "..split[pages - 1].." vstack [vo]"
	end
	mp.set_property("lavfi-complex", vstack)
	local index = mp.get_property_number("playlist-pos")
	local zoom_level = calculate_zoom_level(filedims[index], pages)
	mp.set_property("video-zoom", log2(zoom_level))
	mp.set_property("video-pan-y", 0)
	if alignment == "top" then
		mp.set_property("video-align-y", -1)
	else
		mp.set_property("video-align-y", 1)
	end
end

function set_lavfi_complex_continuous_simple(arg, alignment, pages)
	local vstack = ""
	local split = str_split(arg, " ")
	local total_t = pages - 2
	local t_arr = {}
	for i=0,total_t-1 do
		t_arr[i] = "[t"..tostring(i+1).."]"
	end
	local t_index = 0
	if pages == 4 then
		for i=0,pages-1,2 do
			vstack = vstack..split[i].." "..split[i+1].." vstack "..t_arr[t_index].." ; "
			t_index = t_index + 1
		end
		vstack = vstack.."[t1] [t2] vstack [vo]"
	elseif pages == 3 then
		vstack = vstack..split[0].." "..split[1].." vstack [t1] ; "
		vstack = vstack.."[t1] "..split[2].." vstack [vo]"
	elseif pages == 2 then
		vstack = vstack..split[0].." "..split[1].." vstack [vo]"
	end
	mp.set_property("lavfi-complex", vstack)
	local index = mp.get_property_number("playlist-pos")
	local zoom_level = calculate_zoom_level(filedims[index], pages)
	mp.set_property("video-zoom", log2(zoom_level))
	mp.set_property("video-pan-y", 0)
	if alignment == "top" then
		mp.set_property("video-align-y", -1)
	else
		mp.set_property("video-align-y", 1)
	end
end

function set_lavfi_complex_double(scale)
	-- video track ids load unpredictably so check which one is external
	local external = mp.get_property_bool("track-list/1/external")
	local index = mp.get_property_number("playlist-pos")
	local vid2 = "[vid2]"
	local hstack
	if scale then
		vid2 = "[vid2_scale]"
	end
	if external then
		if opts.manga then
			hstack = vid2.." [vid1] hstack [vo]"
		else
			hstack = "[vid1] "..vid2.." hstack [vo]"
		end
	else
		if opts.manga then
			hstack = "[vid1] "..vid2.." hstack [vo]"
		else
			hstack = vid2.." [vid1] hstack [vo]"
		end
	end
	if scale then
		hstack = "[vid2] scale="..filedims[index][0].."x"..filedims[index][1]..":flags=spline [vid2_scale]; "..hstack
	end
	mp.set_property("lavfi-complex", hstack)
end

function next_page()
	local index = mp.get_property_number("playlist-pos")
	if opts.double and valid_width[index] then
		change_page(2)
	elseif opts.continuous then
		change_page(opts.continuous_size)
	else
		change_page(1)
	end
end

function prev_page()
	local index = mp.get_property_number("playlist-pos")
	if opts.double and valid_width[index] then
		change_page(-2)
	elseif opts.continuous then
		change_page(-opts.continuous_size)
	else
		change_page(-1)
	end
end

function next_single_page()
	change_page(1)
end

function prev_single_page()
	change_page(-1)
end

function skip_forward()
	change_page(opts.skip_size)
end

function skip_backward()
	change_page(-opts.skip_size)
end

function first_page()
	mp.set_property("lavfi-complex", "")
	mp.set_property("playlist-pos", 0);
	change_page(0)
end

function last_page()
	mp.set_property("lavfi-complex", "")
	local len = mp.get_property_number("playlist-count")
	local index = 0;
	if opts.continuous then
		index = len - opts.continuous_size
	elseif opts.double then
		index = len - 2
	else
		index = len - 1
	end
	mp.set_property("playlist-pos", index);
	change_page(0)
	if opts.continuous then
		mp.set_property("video-align-y", 1)
	end
end

function pan_up()
	mp.commandv("add", "video-pan-y", opts.pan_size)
end

function pan_down()
	mp.commandv("add", "video-pan-y", -opts.pan_size)
end

function one_handler()
	input = input.."1"
	mp.osd_message("Jump to page "..input, 100000)
end

function two_handler()
	input = input.."2"
	mp.osd_message("Jump to page "..input, 100000)
end

function three_handler()
	input = input.."3"
	mp.osd_message("Jump to page "..input, 100000)
end

function four_handler()
	input = input.."4"
	mp.osd_message("Jump to page "..input, 100000)
end

function five_handler()
	input = input.."5"
	mp.osd_message("Jump to page "..input, 100000)
end

function six_handler()
	input = input.."6"
	mp.osd_message("Jump to page "..input, 100000)
end

function seven_handler()
	input = input.."7"
	mp.osd_message("Jump to page "..input, 100000)
end

function eight_handler()
	input = input.."8"
	mp.osd_message("Jump to page "..input, 100000)
end

function nine_handler()
	input = input.."9"
	mp.osd_message("Jump to page "..input, 100000)
end

function zero_handler()
	input = input.."0"
	mp.osd_message("Jump to page "..input, 100000)
end

function bs_handler()
	input = input:sub(1, -2)
	mp.osd_message("Jump to page "..input, 100000)
end

function jump_page_go()
	local dest = tonumber(input) - 1
	local len = mp.get_property_number("playlist-count")
	local index = mp.get_property_number("playlist-pos")
	input = ""
	mp.osd_message("")
	if (dest > len - 1) or (dest < 0) then
		mp.osd_message("Specified page does not exist")
	else
		local amount = dest - index
		change_page(amount)
	end
	remove_jump_keys()
	jump = false
end

function remove_jump_keys()
	mp.remove_key_binding("one-handler")
	mp.remove_key_binding("two-handler")
	mp.remove_key_binding("three-handler")
	mp.remove_key_binding("four-handler")
	mp.remove_key_binding("five-handler")
	mp.remove_key_binding("six-handler")
	mp.remove_key_binding("seven-handler")
	mp.remove_key_binding("eight-handler")
	mp.remove_key_binding("nine-handler")
	mp.remove_key_binding("zero-handler")
	mp.remove_key_binding("bs-handler")
	mp.remove_key_binding("jump-page-go")
	mp.remove_key_binding("jump-page-quit")
end

function jump_page_quit()
	jump = false
	input = ""
	remove_jump_keys()
	mp.osd_message("")
end

function set_jump_keys()
	mp.add_forced_key_binding("1", "one-handler", one_handler)
	mp.add_forced_key_binding("2", "two-handler", two_handler)
	mp.add_forced_key_binding("3", "three-handler", three_handler)
	mp.add_forced_key_binding("4", "four-handler", four_handler)
	mp.add_forced_key_binding("5", "five-handler", five_handler)
	mp.add_forced_key_binding("6", "six-handler", six_handler)
	mp.add_forced_key_binding("7", "seven-handler", seven_handler)
	mp.add_forced_key_binding("8", "eight-handler", eight_handler)
	mp.add_forced_key_binding("9", "nine-handler", nine_handler)
	mp.add_forced_key_binding("0", "zero-handler", zero_handler)
	mp.add_forced_key_binding("BS", "bs-handler", bs_handler)
	mp.add_forced_key_binding("ENTER", "jump-page-go", jump_page_go)
	mp.add_forced_key_binding("ctrl+[", "jump-page-quit", jump_page_quit)
end

function jump_page_mode()
	if jump == false then
		jump = true
		set_jump_keys()
		mp.osd_message("Jump to page ", 100000)
	end
end

function set_keys()
	if opts.manga then
		mp.add_forced_key_binding("LEFT", "next-page", next_page)
		mp.add_forced_key_binding("RIGHT", "prev-page", prev_page)
		mp.add_forced_key_binding("Shift+LEFT", "next-single-page", next_single_page)
		mp.add_forced_key_binding("Shift+RIGHT", "prev-single-page", prev_single_page)
		mp.add_forced_key_binding("Ctrl+LEFT", "skip-forward", skip_forward)
		mp.add_forced_key_binding("Ctrl+RIGHT", "skip-backward", skip_backward)
	else
		mp.add_forced_key_binding("RIGHT", "next-page", next_page)
		mp.add_forced_key_binding("LEFT", "prev-page", prev_page)
		mp.add_forced_key_binding("Shift+RIGHT", "next-single-page", next_single_page)
		mp.add_forced_key_binding("Shift+LEFT", "prev-single-page", prev_single_page)
		mp.add_forced_key_binding("Ctrl+RIGHT", "skip-forward", skip_forward)
		mp.add_forced_key_binding("Ctrl+LEFT", "skip-backward", skip_backward)
	end
	mp.add_forced_key_binding("UP", "pan-up", pan_up)
	mp.add_forced_key_binding("DOWN", "pan-down", pan_down)
	mp.add_forced_key_binding("HOME", "first-page", first_page)
	mp.add_forced_key_binding("END", "last-page", last_page)
	mp.add_forced_key_binding("/", "jump-page-mode", jump_page_mode)
end

function remove_keys()
	mp.remove_key_binding("next-page")
	mp.remove_key_binding("prev-page")
	mp.remove_key_binding("next-single-page")
	mp.remove_key_binding("prev-single-page")
	mp.remove_key_binding("skip-forward")
	mp.remove_key_binding("skip-backward")
	mp.remove_key_binding("pan-up")
	mp.remove_key_binding("pan-down")
	mp.remove_key_binding("first-page")
	mp.remove_key_binding("last-page")
	mp.remove_key_binding("jump-page-mode")
end

function remove_non_images()
	local length = mp.get_property_number("playlist-count")
	local i = 0
	local name = mp.get_property("playlist/"..tostring(i).."/filename")
	while name ~= nil do
		local sub = string.sub(name, -5)
		local match = false
		for j=1,9 do
			if string.match(sub, ext[j]) then
				match = true
				break
			end
		end
		if not match then
			mp.commandv("playlist-remove", i)
		end
		i = i + 1
		name = mp.get_property("playlist/"..tostring(i).."/filename")
	end
end

function fill_width_height_array()
	local length = mp.get_property_number("playlist-count")
	for i=0,length-2 do
		if filedims[i][0] == filedims[i+1][0] then
			valid_width[i] = true
		else
			valid_width[i] = false
		end
		if filedims[i][1] == filedims[i+1][1] then
			valid_height[i] = true
		else
			valid_height[i] = false
		end
	end
end

function sleep(seconds)
	local time = os.clock() + seconds
	repeat until os.clock() > time
end

function store_image_dims()
	mp.set_property("brightness", -100)
	mp.set_property("contrast", -100)
	mp.set_property_bool("really-quiet", true)
	local length = mp.get_property_number("playlist-count")
	for i=0,length-1 do
		local dims = {}
		local width = mp.get_property_number("width")
		while width == nil do
			width = mp.get_property_number("width")
		end
		local height = mp.get_property_number("height")
		while height == nil do
			height = mp.get_property_number("height")
		end
		dims[0] = width
		dims[1] = height
		filedims[i] = dims
		height = nil
		width = nil
		mp.commandv("playlist-next")
		--hack a sleep in here so the properties load correctly
		sleep(0.05)
	end
	mp.set_property("playlist-pos", 0)
	mp.set_property("brightness", 0)
	mp.set_property("contrast", 0)
	mp.set_property_bool("really-quiet", false)
end

function str_split(str, delim)
	local split = {}
	local i = 0
	for token in string.gmatch(str, "([^"..delim.."]+)") do
		split[i] = token
		i = i + 1
	end
	return split
end

function toggle_reader()
	local image = check_images()
	if image then
		remove_non_images()
		if filedims[0] == nil then
			store_image_dims()
		end
		if valid_width[0] == nil then
			fill_width_height_array()
		end
		if opts.continuous then
			opts.double = false
			opts.continuous = true
			mp.observe_property("video-pan-y", number, check_y_pos)
		end
		if not initiated then
			set_keys()
			initiated = true
			mp.osd_message("Manga Reader Started")
			mp.set_property_bool("force-window", true)
			mp.add_key_binding("c", "toggle-continuous-mode", toggle_continuous_mode)
			mp.add_key_binding("d", "toggle-double-page", toggle_double_page)
			mp.add_key_binding("m", "toggle-manga-mode", toggle_manga_mode)
			mp.register_event("end-file", check_lavfi_complex)
			change_page(0)
		else
			remove_keys()
			initiated = false
			mp.unobserve_property(check_y_pos)
			mp.set_property("video-zoom", 0)
			mp.set_property("video-align-y", 0)
			mp.set_property("video-pan-y", 0)
			mp.set_property("lavfi-complex", "")
			mp.set_property_bool("force-window", false)
			mp.remove_key_binding("toggle-continuous-mode")
			mp.remove_key_binding("toggle-double-page")
			mp.remove_key_binding("toggle-manga-mode")
			mp.osd_message("Closing Reader")
			mp.unregister_event(check_lavfi_complex)
			change_page(0)
		end
	else
		if not first_start then
			mp.osd_message("Not an image")
		end
	end
end

function init()
	if opts.auto_start then
		toggle_reader()
	end
	mp.unregister_event(init)
	first_start = false
end

function check_y_pos()
	if opts.continuous then
		local index = mp.get_property_number("playlist-pos")
		local len = mp.get_property_number("playlist-count")
		local first_chunk = false
		if index+opts.continuous_size < 0 then
			first_chunk = true
		elseif index == 0 then
			first_chunk = true
		end
		local last_chunk = false
		if index+opts.continuous_size >= len - 1 then
			last_chunk = true
		end
		local middle_index
		if index == len - 1 then
			middle_index = index - 1
		else
			middle_index = index + 1
		end
		local total_height = mp.get_property("height")
		if total_height == nil then
			return
		end
		local y_pos = mp.get_property_number("video-pan-y")
		local y_align = mp.get_property_number("video-align-y")
		if y_align == -1 then
			local height = filedims[middle_index][1]
			local bottom_threshold = height / total_height - 1 - opts.trigger_zone
			if y_pos < bottom_threshold and not last_chunk then
				next_page()
			end
			if y_pos > 0 and not first_chunk then
				prev_page()
			end
		elseif y_align == 1 then
			local height = filedims[middle_index][1]
			local top_threshold = 1 - height / total_height + opts.trigger_zone
			if y_pos > top_threshold and not first_chunk then
				prev_page()
			end
			if y_pos < 0 and not last_chunk then
				next_page()
			end
		end
	end
end

function toggle_continuous_mode()
	if opts.continuous then
		mp.osd_message("Continuous Mode Off")
		opts.continuous = false
		mp.unobserve_property(check_y_pos)
		mp.set_property("video-zoom", 0)
		mp.set_property("video-align-y", 0)
		mp.set_property("video-pan-y", 0)
	else
		mp.osd_message("Continuous Mode On")
		opts.double = false
		opts.continuous = true
		mp.observe_property("video-pan-y", number, check_y_pos)
	end
	change_page(0)
end

function toggle_double_page()
	if opts.double then
		mp.osd_message("Double Page Mode Off")
		opts.double = false
	else
		mp.osd_message("Double Page Mode On")
		opts.continuous = false
		opts.double = true
	end
	change_page(0)
end

function toggle_manga_mode()
	if opts.manga then
		mp.osd_message("Manga Mode Off")
		opts.manga = false
	else
		mp.osd_message("Manga Mode On")
		opts.manga = true
	end
	set_keys()
	change_page(0)
end

mp.register_event("file-loaded", init)
mp.add_key_binding("y", "toggle-reader", toggle_reader)
read_options(opts, "manga-reader")
