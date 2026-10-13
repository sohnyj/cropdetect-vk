--[[
    # Usage
    KEY script-message toggle_autocrop
--]]

local mp = require "mp"
local msg = require "mp.msg"
local options = require "mp.options"

local autocrop_opts = {
    osd = "Autocrop",
    label = "autocrop",
    cropdetect_limit = "24/255",
    cropdetect_round = 2,
    min_apply_width = 0.5,
    min_apply_height = 0.5,
    symmetry_ratio = 0.75,
    crop_tolerance = 0.01,
}
options.read_options(autocrop_opts)

local FILTER_LABEL = "@" .. autocrop_opts.label
local UPLOAD_LABEL = "@" .. autocrop_opts.label .. "_upload"
local UPLOAD_COMMAND = "%s:format=fmt=vulkan" -- uploads CUDA and software frames to Vulkan
local VULKAN_PIXELFORMAT = "vulkan"
local FILTER_COMMAND = "%s:cropdetect_vulkan=limit=%s:reset=%d:round=%d"
local METADATA_PROPERTY = "vf-metadata/" .. autocrop_opts.label
local METADATA_KEY_PREFIX = "lavfi.cropdetect."
local VULKAN_CONTEXT_SUFFIX = "vk"
local USERDATA_PROPERTY = "user-data/filter/" .. autocrop_opts.label
local POLL_FRAMES = 10 -- video frames between cropdetect metadata polls
local POLL_INTERVAL_RESOLUTION = 10 -- poll interval rounding steps per second
local RESET_MARGIN_FRAMES = 2 -- frames by which the cropdetect reset window is shorter than the poll interval
local MIN_RESET_FRAMES = 1 -- cropdetect reset=0 means never reset
local DEBOUNCE_POLLS = 2 -- poll intervals a detected crop must stay unchanged before it is applied
local MAX_DETECT_SPEED = 1 -- playback speed above which detection is skipped

local autocrop_state = {
    active = false,
    poll_timer = nil,
    debounce_sec = 0,
    properties = { speed = 1, seeking = false },
    pending = {},
}

local function set_active(active)
    autocrop_state.active = active
    mp.set_property_native(USERDATA_PROPERTY, active)
end

set_active(false)

local function is_vulkan_context()
    local gpu_context = mp.get_property("current-gpu-context")
    return gpu_context ~= nil and gpu_context:sub(-#VULKAN_CONTEXT_SUFFIX) == VULKAN_CONTEXT_SUFFIX
end

local function get_video_fps()
    local fps = mp.get_property_native("container-fps")
    if not fps then
        msg.warn("Limit: no fps")
        return nil
    end
    return fps
end

local function get_poll_interval(fps)
    return math.max(math.floor(POLL_FRAMES / fps * POLL_INTERVAL_RESOLUTION + 0.5) / POLL_INTERVAL_RESOLUTION,
        1 / POLL_INTERVAL_RESOLUTION)
end

local function needs_upload()
    return mp.get_property("video-params/pixelformat") ~= VULKAN_PIXELFORMAT
end

local function is_filter_active(label)
    for _, filter in ipairs(mp.get_property_native("vf") or {}) do
        if "@" .. (filter.label or "") == label then
            return true
        end
    end
    return false
end

local function insert_autocrop(fps, poll_interval)
    if is_filter_active(FILTER_LABEL) then
        return
    end

    local reset_frames = math.max(math.floor(poll_interval * fps + 0.5) - RESET_MARGIN_FRAMES, MIN_RESET_FRAMES)
    if needs_upload() then
        mp.commandv("vf", "append", string.format(UPLOAD_COMMAND, UPLOAD_LABEL))
    end
    mp.commandv("vf", "append", string.format(FILTER_COMMAND,
        FILTER_LABEL, autocrop_opts.cropdetect_limit, reset_frames, autocrop_opts.cropdetect_round))
end

local function clamp_autocrop(crop_size, crop_pos, min_size, max_size)
    if max_size - crop_size <= max_size * autocrop_opts.crop_tolerance then
        return max_size, 0
    end

    crop_size = math.max(crop_size, min_size)
    crop_pos = math.min(crop_pos, max_size - crop_size)

    local margin_start = crop_pos
    local margin_end = max_size - crop_size - crop_pos
    if math.min(margin_start, margin_end) < math.max(margin_start, margin_end) * autocrop_opts.symmetry_ratio then
        return max_size, 0
    end
    return crop_size, crop_pos
end

local function is_same_crop(crop, other, max_w, max_h)
    local tolerance_w = max_w * autocrop_opts.crop_tolerance
    local tolerance_h = max_h * autocrop_opts.crop_tolerance
    return math.abs(crop.w - other.w) <= tolerance_w and math.abs(crop.x - other.x) <= tolerance_w
        and math.abs(crop.h - other.h) <= tolerance_h and math.abs(crop.y - other.y) <= tolerance_h
end

local function apply_autocrop(crop, max_w, max_h)
    if crop.w == max_w and crop.h == max_h then
        mp.set_property("video-crop", "")
    else
        mp.set_property("video-crop", string.format("%dx%d+%d+%d", crop.w, crop.h, crop.x, crop.y))
    end
end

local function debounce_autocrop(crop, max_w, max_h)
    local pending = autocrop_state.pending
    if not pending.crop or not is_same_crop(crop, pending.crop, max_w, max_h) then
        autocrop_state.pending = { crop = crop, time = mp.get_time(), applied = false }
    elseif not pending.applied and mp.get_time() - pending.time >= autocrop_state.debounce_sec then
        pending.applied = true
        apply_autocrop(pending.crop, max_w, max_h)
    end
end

local function update_autocrop()
    local cropdetect_metadata = mp.get_property_native(METADATA_PROPERTY)
    if not cropdetect_metadata then return end

    local max_w = mp.get_property_native("video-out-params/w")
    local max_h = mp.get_property_native("video-out-params/h")
    if not max_w or not max_h then return end

    local w = tonumber(cropdetect_metadata[METADATA_KEY_PREFIX .. "w"])
    local h = tonumber(cropdetect_metadata[METADATA_KEY_PREFIX .. "h"])
    local x = tonumber(cropdetect_metadata[METADATA_KEY_PREFIX .. "x"])
    local y = tonumber(cropdetect_metadata[METADATA_KEY_PREFIX .. "y"])
    if not (w and h and x and y) then return end

    local crop = {}
    crop.w, crop.x = clamp_autocrop(w, x, max_w * autocrop_opts.min_apply_width, max_w)
    crop.h, crop.y = clamp_autocrop(h, y, max_h * autocrop_opts.min_apply_height, max_h)
    debounce_autocrop(crop, max_w, max_h)
end

local function limit_autocrop()
    local properties = autocrop_state.properties
    if properties.seeking or properties.speed > MAX_DETECT_SPEED then
        return
    end
    update_autocrop()
end

local function reset_autocrop_state()
    autocrop_state.pending = {}
end

local function handle_speed(_, value)
    autocrop_state.properties.speed = value
end

local function handle_seeking(_, value)
    autocrop_state.properties.seeking = value
    if value then reset_autocrop_state() end
end

local function handle_pause(_, value)
    if not autocrop_state.poll_timer then
        return
    end

    if value then
        autocrop_state.poll_timer:kill()
    else
        autocrop_state.poll_timer:resume()
    end
end

local function observe_properties()
    mp.observe_property("speed", "number", handle_speed)
    mp.observe_property("seeking", "bool", handle_seeking)
    mp.observe_property("pause", "bool", handle_pause)
end

local function unobserve_properties()
    mp.unobserve_property(handle_speed)
    mp.unobserve_property(handle_seeking)
    mp.unobserve_property(handle_pause)
    autocrop_state.properties = { speed = 1, seeking = false }
end

local function start_autocrop(fps)
    local poll_interval = get_poll_interval(fps)
    autocrop_state.debounce_sec = poll_interval * DEBOUNCE_POLLS

    insert_autocrop(fps, poll_interval)
    autocrop_state.poll_timer = mp.add_periodic_timer(poll_interval, limit_autocrop)
    observe_properties()
end

local function cleanup_autocrop()
    unobserve_properties()
    if autocrop_state.poll_timer then
        autocrop_state.poll_timer:kill()
        autocrop_state.poll_timer = nil
    end

    if is_filter_active(FILTER_LABEL) then
        mp.commandv("vf", "remove", FILTER_LABEL)
    end
    if is_filter_active(UPLOAD_LABEL) then
        mp.commandv("vf", "remove", UPLOAD_LABEL)
    end
    mp.set_property("video-crop", "")
    reset_autocrop_state()
end

local function enable_autocrop(suppress_osd)
    local fps = get_video_fps()
    if not fps then
        return
    end

    start_autocrop(fps)
    set_active(true)
    if not suppress_osd then
        mp.osd_message(autocrop_opts.osd .. ": yes")
    end
end

local function disable_autocrop(suppress_osd)
    cleanup_autocrop()
    set_active(false)
    if not suppress_osd then
        mp.osd_message(autocrop_opts.osd .. ": no")
    end
end

local function handle_toggle(command, suppress_osd)
    local enable = command == "enable" or (command == nil and not autocrop_state.active)
    if enable == autocrop_state.active then
        return
    end

    if enable and mp.get_property_native("current-tracks/video/image") then
        msg.warn("Limit: image file")
        return
    end

    if enable and not is_vulkan_context() then
        msg.warn("Limit: gpu-context is not vulkan")
        return
    end

    if enable then
        enable_autocrop(suppress_osd)
    else
        disable_autocrop(suppress_osd)
    end
end

mp.register_event("end-file", function() handle_toggle("disable", true) end)
mp.register_script_message("toggle_autocrop", handle_toggle)
mp.register_script_message("enable", function() handle_toggle("enable", true) end)
mp.register_script_message("disable", function() handle_toggle("disable", true) end)
