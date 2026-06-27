local bento_data = include("midi-lfo/lib/bento_cc_index")

local DATA_DIR = _path.data .. "bento_lfo_cc/"
local STATE_FILE = DATA_DIR .. "state.data"

local PAGE_GLOBAL = 1
local PAGE_ROUTE = 2
local PAGE_LFO = 3
local STATE_VERSION = 2

local LANE_COUNT = 32
local GRID_BANK_COUNT = 4
local GRID_BANK_ROWS = 8
local GRID_VALUE_COL_MIN = 2
local GRID_VALUE_COL_MAX = 15
local GRID_HOLD_SECONDS = 3.0
local MIN_RATE_HZ = 0.001
local MAX_RATE_HZ = 20.0

local SHAPES = {
  "sin",
  "saw",
  "reverse_saw",
  "triangle",
  "sample_hold",
}

local ui = {
  page = PAGE_GLOBAL,
  page_count = 3,
  selection = {
    [PAGE_GLOBAL] = 1,
    [PAGE_ROUTE] = 1,
    [PAGE_LFO] = 1,
  },
  selected_lane = 1,
  grid_bank = 1,
  output_device = 1,
  dirty = true,
}

local lanes = {}
local output_midi
local redraw_timer
local lfo_clock
local lfo_running = false
local midigrid_lib
local midigrid_2pages_lib
local using_midigrid = false
local grid_hold = {
  active = false,
  lane_index = nil,
  row = nil,
  base_col = nil,
  base_value = nil,
  started_at = 0,
  highest_col = nil,
  value_col_min = GRID_VALUE_COL_MIN,
  value_col_max = GRID_VALUE_COL_MAX,
}

local function mark_dirty()
  ui.dirty = true
end

local function encoder_delta(value)
  if value == nil or value == 0 then
    return 0
  elseif value > 0 then
    return 1
  end
  return -1
end

local function short_name(name)
  if name == nil or name == "" then
    return "none"
  end
  if string.len(name) <= 12 then
    return name
  end
  return util.acronym(name)
end

local function try_include(path)
  local ok, lib = pcall(function()
    return include(path)
  end)

  if ok then
    return lib
  end

  return nil
end

local function default_lane()
  return {
    channel = 1,
    instrument_index = 1,
    context_index = 1,
    parameter_index = 1,
    base = 64,
    shape_index = 1,
    rate = 0.1,
    depth = 0,
    phase = 0,
    sh_value = 0,
    last_sent_value = nil,
    last_sent_cc = nil,
    last_sent_channel = nil,
    current_value = 64,
  }
end

local function lane_bank(index)
  return math.floor(((index or 1) - 1) / GRID_BANK_ROWS) + 1
end

local function clamp_grid_bank(bank)
  return util.clamp(bank or 1, 1, GRID_BANK_COUNT)
end

local function set_selected_lane(index, follow_grid_bank)
  local lane_index = util.clamp(index or 1, 1, LANE_COUNT)
  ui.selected_lane = lane_index
  if follow_grid_bank ~= false then
    ui.grid_bank = clamp_grid_bank(lane_bank(lane_index))
  end
end

local function set_grid_bank(bank)
  ui.grid_bank = clamp_grid_bank(bank)
end

local function native_grid_connected()
  if grid == nil or grid.vports == nil then
    return false
  end

  local port = grid.vports[1]
  if port == nil or port.name == nil then
    return false
  end

  local name = string.lower(tostring(port.name))
  return name ~= "" and name ~= "none"
end

local function connect_grid_device()
  using_midigrid = false

  if native_grid_connected() then
    return grid.connect()
  end

  if midigrid_2pages_lib == nil then
    midigrid_2pages_lib = try_include("midigrid/lib/midigrid_2pages")
  end

  if midigrid_lib == nil then
    midigrid_lib = try_include("midigrid/lib/mg_128")
  end

  if midigrid_2pages_lib ~= nil and midigrid_2pages_lib.connect ~= nil then
    using_midigrid = true
    return midigrid_2pages_lib.connect()
  end

  if midigrid_lib ~= nil and midigrid_lib.connect ~= nil then
    using_midigrid = true
    return midigrid_lib.connect()
  end

  return nil
end

local function available_instrument_count()
  return #bento_data.instrument_types
end

local function instrument_name(index)
  local count = available_instrument_count()
  if count < 1 then
    return nil
  end
  local clamped = util.clamp(index or 1, 1, count)
  return bento_data.instrument_types[clamped]
end

local function instrument_data(index)
  local name = instrument_name(index)
  if name == nil then
    return nil, nil
  end
  return name, bento_data.by_instrument[name]
end

local function contexts_for_instrument(index)
  local _, inst = instrument_data(index)
  if inst == nil or inst.contexts == nil then
    return {}
  end
  return inst.contexts
end

local function parameters_for_selection(lane)
  local inst_name, inst = instrument_data(lane.instrument_index)
  if inst_name == nil or inst == nil then
    return nil, nil, {}
  end

  local contexts = contexts_for_instrument(lane.instrument_index)
  local context_count = #contexts
  if context_count < 1 then
    return inst_name, nil, {}
  end

  lane.context_index = util.clamp(lane.context_index or 1, 1, context_count)
  local context = contexts[lane.context_index]
  local params = inst.by_context[context] or {}
  if #params < 1 then
    return inst_name, context, {}
  end

  lane.parameter_index = util.clamp(lane.parameter_index or 1, 1, #params)
  return inst_name, context, params
end

local function current_entry(lane)
  local inst_name, context, params = parameters_for_selection(lane)
  if inst_name == nil or context == nil or #params < 1 then
    return nil, nil, nil, nil
  end

  local entry = params[lane.parameter_index]
  if entry == nil then
    return inst_name, context, nil, nil
  end

  local parameter = entry.parameter
  if parameter == nil or parameter == "" then
    parameter = "(none)"
  end

  return inst_name, context, entry.midi_cc, parameter
end

local function ensure_lane_indices(lane)
  local inst_count = available_instrument_count()
  if inst_count < 1 then
    lane.instrument_index = 1
    lane.context_index = 1
    lane.parameter_index = 1
    return
  end

  lane.instrument_index = util.clamp(lane.instrument_index or 1, 1, inst_count)

  local contexts = contexts_for_instrument(lane.instrument_index)
  if #contexts < 1 then
    lane.context_index = 1
    lane.parameter_index = 1
    return
  end

  lane.context_index = util.clamp(lane.context_index or 1, 1, #contexts)

  local _, inst = instrument_data(lane.instrument_index)
  local context = contexts[lane.context_index]
  local params = inst.by_context[context] or {}
  if #params < 1 then
    lane.parameter_index = 1
    return
  end

  lane.parameter_index = util.clamp(lane.parameter_index or 1, 1, #params)
end

local function reset_lane_history(lane)
  lane.last_sent_value = nil
  lane.last_sent_cc = nil
  lane.last_sent_channel = nil
end

local function set_output_device(device)
  ui.output_device = util.clamp(device or 1, 1, 16)
  output_midi = midi.connect(ui.output_device)
end

local function load_state()
  if util.file_exists(STATE_FILE) then
    local saved = tab.load(STATE_FILE)
    if saved ~= nil then
      local needs_depth_reset = (saved.version == nil) or (saved.version < STATE_VERSION)
      ui.output_device = util.clamp(saved.output_device or ui.output_device, 1, 16)
      ui.selected_lane = util.clamp(saved.selected_lane or ui.selected_lane, 1, LANE_COUNT)
      ui.grid_bank = clamp_grid_bank(saved.grid_bank or lane_bank(ui.selected_lane))
      if saved.lanes ~= nil then
        for i = 1, LANE_COUNT do
          local lane = lanes[i]
          local src = saved.lanes[i]
          if lane ~= nil and src ~= nil then
            lane.channel = util.clamp(src.channel or lane.channel, 1, 16)
            lane.instrument_index = src.instrument_index or lane.instrument_index
            lane.context_index = src.context_index or lane.context_index
            lane.parameter_index = src.parameter_index or lane.parameter_index
            lane.base = util.clamp(src.base or lane.base, 0, 127)
            lane.shape_index = util.clamp(src.shape_index or lane.shape_index, 1, #SHAPES)
            lane.rate = util.clamp(src.rate or lane.rate, MIN_RATE_HZ, MAX_RATE_HZ)
            if needs_depth_reset then
              lane.depth = 0
            else
              lane.depth = util.clamp(src.depth or lane.depth, 0, 127)
            end
            lane.phase = src.phase or lane.phase
            lane.sh_value = src.sh_value or lane.sh_value
          end
        end
      end
    end
  else
    util.make_dir(DATA_DIR)
  end
end

local function save_state()
  local saved_lanes = {}
  for i = 1, LANE_COUNT do
    local lane = lanes[i]
    saved_lanes[i] = {
      channel = lane.channel,
      instrument_index = lane.instrument_index,
      context_index = lane.context_index,
      parameter_index = lane.parameter_index,
      base = lane.base,
      shape_index = lane.shape_index,
      rate = lane.rate,
      depth = lane.depth,
      phase = lane.phase,
      sh_value = lane.sh_value,
    }
  end

  tab.save({
      version = STATE_VERSION,
    output_device = ui.output_device,
    selected_lane = ui.selected_lane,
    grid_bank = ui.grid_bank,
    lanes = saved_lanes,
  }, STATE_FILE)
end

local function rate_step(rate)
  return 0.001
end

local function grid_lane_level(lane_index)
  return lane_index == ui.selected_lane and 15 or 5
end

local function grid_col_to_value(col, value_col_min, value_col_max)
  local span = math.max(1, value_col_max - value_col_min)
  local normalized = util.clamp((col - value_col_min) / span, 0, 1)
  return util.clamp(math.floor((normalized * 127) + 0.5), 0, 127)
end

local function clear_grid_hold()
  grid_hold.active = false
  grid_hold.lane_index = nil
  grid_hold.row = nil
  grid_hold.base_col = nil
  grid_hold.base_value = nil
  grid_hold.started_at = 0
  grid_hold.highest_col = nil
  grid_hold.value_col_min = GRID_VALUE_COL_MIN
  grid_hold.value_col_max = GRID_VALUE_COL_MAX
end

local function start_grid_hold(lane_index, row, col, value_col_min, value_col_max)
  grid_hold.active = true
  grid_hold.lane_index = lane_index
  grid_hold.row = row
  grid_hold.base_col = col
  grid_hold.base_value = grid_col_to_value(col, value_col_min, value_col_max)
  grid_hold.started_at = util.time()
  grid_hold.highest_col = nil
  grid_hold.value_col_min = value_col_min
  grid_hold.value_col_max = value_col_max
end

local function maybe_commit_grid_hold()
  if not grid_hold.active or grid_hold.lane_index == nil then
    return
  end

  local held_for = util.time() - (grid_hold.started_at or 0)
  if held_for < GRID_HOLD_SECONDS then
    clear_grid_hold()
    return
  end

  local lane = lanes[grid_hold.lane_index]
  if lane ~= nil and grid_hold.base_value ~= nil then
    lane.base = util.clamp(grid_hold.base_value, 0, 127)
    if grid_hold.highest_col ~= nil then
      local highest_value = grid_col_to_value(grid_hold.highest_col, grid_hold.value_col_min, grid_hold.value_col_max)
      lane.depth = util.clamp(math.abs(highest_value - lane.base), 0, 127)
    end
  end

  clear_grid_hold()
  mark_dirty()
end

local function redraw_grid()
  if grid_device == nil then
    return
  end

  grid_device:all(0)

  local page_start = ((ui.grid_bank - 1) * GRID_BANK_ROWS) + 1
  local page_stop = math.min(page_start + GRID_BANK_ROWS - 1, LANE_COUNT)
  local page_col = grid_device.cols or 16
  if page_col > 16 then
    page_col = 16
  end
  local value_col_min = GRID_VALUE_COL_MIN
  local value_col_max = math.min(GRID_VALUE_COL_MAX, page_col - 1)

  for row = 1, GRID_BANK_ROWS do
    local lane_index = page_start + row - 1
    if lane_index <= page_stop then
      local lane = lanes[lane_index]
      local select_level = grid_lane_level(lane_index)
      grid_device:led(1, row, select_level)

      if value_col_max >= value_col_min then
        local value = lane and lane.current_value or 0
        -- Blend neighboring columns for smoother perceived motion as values change.
        local span = math.max(1, value_col_max - value_col_min)
        local position = ((value / 127) * span) + value_col_min
        local left_col = util.clamp(math.floor(position), value_col_min, value_col_max)
        local right_col = util.clamp(left_col + 1, value_col_min, value_col_max)
        local frac = util.clamp(position - left_col, 0, 1)

        if right_col == left_col then
          grid_device:led(left_col, row, select_level)
        else
          -- Sharper than linear crossfade: nearest column stays dominant longer.
          local sharpness = 2.2
          local left_weight = math.pow(1 - frac, sharpness)
          local right_weight = math.pow(frac, sharpness)
          local weight_total = left_weight + right_weight
          local left_level = 0
          local right_level = 0

          if weight_total > 0 then
            left_level = util.clamp(math.floor(((left_weight / weight_total) * select_level) + 0.5), 0, 15)
            right_level = util.clamp(math.floor(((right_weight / weight_total) * select_level) + 0.5), 0, 15)
          end

          if left_level > 0 then
            grid_device:led(left_col, row, left_level)
          end
          if right_level > 0 then
            grid_device:led(right_col, row, right_level)
          end
        end
      end
    end
  end

  for bank = 1, GRID_BANK_COUNT do
    grid_device:led(page_col, bank, bank == ui.grid_bank and 8 or 2)
  end

  grid_device:refresh()
end

local function adjust_global(delta)
  if delta == 0 then
    return
  end

  if ui.selection[PAGE_GLOBAL] == 1 then
    set_output_device(ui.output_device + delta)
  elseif ui.selection[PAGE_GLOBAL] == 2 then
    set_selected_lane(ui.selected_lane + delta)
  end
end

local function adjust_route(delta)
  if delta == 0 then
    return
  end

  local lane = lanes[ui.selected_lane]
  local field = ui.selection[PAGE_ROUTE]

  if field == 1 then
    lane.channel = util.clamp(lane.channel + delta, 1, 16)
  elseif field == 2 then
    lane.instrument_index = util.clamp(lane.instrument_index + delta, 1, available_instrument_count())
    lane.context_index = 1
    lane.parameter_index = 1
    reset_lane_history(lane)
  elseif field == 3 then
    local contexts = contexts_for_instrument(lane.instrument_index)
    if #contexts > 0 then
      lane.context_index = util.clamp(lane.context_index + delta, 1, #contexts)
      lane.parameter_index = 1
      reset_lane_history(lane)
    end
  elseif field == 4 then
    local _, _, params = parameters_for_selection(lane)
    if #params > 0 then
      lane.parameter_index = util.clamp(lane.parameter_index + delta, 1, #params)
      reset_lane_history(lane)
    end
  end

  ensure_lane_indices(lane)
end

local function adjust_lfo(delta)
  if delta == 0 then
    return
  end

  local lane = lanes[ui.selected_lane]
  local field = ui.selection[PAGE_LFO]

  if field == 1 then
    lane.base = util.clamp(lane.base + delta, 0, 127)
  elseif field == 2 then
    lane.shape_index = util.clamp(lane.shape_index + delta, 1, #SHAPES)
  elseif field == 3 then
    local step = rate_step(lane.rate)
    lane.rate = util.clamp(lane.rate + (delta * step), MIN_RATE_HZ, MAX_RATE_HZ)
  elseif field == 4 then
    lane.depth = util.clamp(lane.depth + delta, 0, 127)
  end
end

local function wave_value(lane, shape)
  local phase = lane.phase

  if shape == "sin" then
    return math.sin(phase * math.pi * 2)
  elseif shape == "saw" then
    return (phase * 2) - 1
  elseif shape == "reverse_saw" then
    return 1 - (phase * 2)
  elseif shape == "triangle" then
    if phase < 0.5 then
      return (phase * 4) - 1
    end
    return 3 - (phase * 4)
  elseif shape == "sample_hold" then
    return lane.sh_value or 0
  end

  return 0
end

local function advance_phase(lane, dt)
  local next_phase = lane.phase + (lane.rate * dt)
  local wraps = 0

  if next_phase >= 1 then
    wraps = math.floor(next_phase)
    next_phase = next_phase - wraps
  end

  lane.phase = next_phase

  local shape = SHAPES[lane.shape_index]
  if shape == "sample_hold" and wraps > 0 then
    lane.sh_value = (math.random() * 2) - 1
  end
end

local function send_lane_value(lane)
  if output_midi == nil then
    return
  end

  local _, _, cc = current_entry(lane)
  if cc == nil then
    return
  end

  local wave = wave_value(lane, SHAPES[lane.shape_index])
  local value = util.clamp(math.floor(lane.base + (wave * lane.depth) + 0.5), 0, 127)

  lane.current_value = value

  if lane.last_sent_value == value
      and lane.last_sent_cc == cc
      and lane.last_sent_channel == lane.channel then
    return
  end

  output_midi:cc(cc, value, lane.channel)
  lane.last_sent_value = value
  lane.last_sent_cc = cc
  lane.last_sent_channel = lane.channel
end

local function run_lfos()
  lfo_running = true
  lfo_clock = clock.run(function()
    local last_time = util.time()
    while lfo_running do
      local now = util.time()
      local dt = now - last_time
      if dt <= 0 then
        dt = 1 / 30
      end
      if dt > 0.25 then
        dt = 0.25
      end
      last_time = now

      for i = 1, LANE_COUNT do
        local lane = lanes[i]
        ensure_lane_indices(lane)
        advance_phase(lane, dt)
        send_lane_value(lane)
      end

      mark_dirty()
      clock.sleep(1 / 30)
    end
  end)
end

local function stop_lfos()
  lfo_running = false
  if lfo_clock ~= nil then
    clock.cancel(lfo_clock)
    lfo_clock = nil
  end
end

local function start_redraw_timer()
  redraw_timer = metro.init()
  redraw_timer.time = 1 / 15
  redraw_timer.count = -1
  redraw_timer.event = function()
    if ui.dirty then
      redraw()
    end
  end
  redraw_timer:start()
end

local function stop_redraw_timer()
  if redraw_timer ~= nil then
    redraw_timer:stop()
    redraw_timer = nil
  end
end

local function draw_field(y, label, value, selected)
  if selected then
    screen.level(15)
  else
    screen.level(4)
  end
  screen.move(1, y)
  screen.text(label)
  screen.move(64, y)
  screen.text_right(value)
end

local function lane_context_text(lane)
  local _, context = current_entry(lane)
  if context == nil then
    return "none"
  end
  return short_name(context)
end

local function lane_parameter_text(lane)
  local _, _, cc, parameter = current_entry(lane)
  if cc == nil then
    return "none"
  end
  local left = string.format("cc%03d", cc)
  return left .. " " .. short_name(parameter)
end

local function draw_global_page()
  local lane = lanes[ui.selected_lane]
  draw_field(14, "out", string.format("%d %s", ui.output_device, short_name(midi.vports[ui.output_device] and midi.vports[ui.output_device].name)), ui.selection[PAGE_GLOBAL] == 1)
  draw_field(24, "lane", string.format("%02d/%02d", ui.selected_lane, LANE_COUNT), ui.selection[PAGE_GLOBAL] == 2)
  draw_field(36, "ctx", lane_context_text(lane), false)
  draw_field(46, "param", lane_parameter_text(lane), false)
  draw_field(56, "value", tostring(lane.current_value or lane.base), false)
end

local function draw_route_page()
  local lane = lanes[ui.selected_lane]
  local inst_name = instrument_name(lane.instrument_index) or "none"
  draw_field(14, "lane", string.format("%02d", ui.selected_lane), false)
  draw_field(24, "ch", tostring(lane.channel), ui.selection[PAGE_ROUTE] == 1)
  draw_field(34, "inst", short_name(inst_name), ui.selection[PAGE_ROUTE] == 2)
  draw_field(44, "ctx", lane_context_text(lane), ui.selection[PAGE_ROUTE] == 3)
  draw_field(54, "param", lane_parameter_text(lane), ui.selection[PAGE_ROUTE] == 4)
end

local function draw_lfo_page()
  local lane = lanes[ui.selected_lane]
  local shape = SHAPES[lane.shape_index]
  draw_field(14, "lane", string.format("%02d", ui.selected_lane), false)
  draw_field(24, "base", tostring(lane.base), ui.selection[PAGE_LFO] == 1)
  draw_field(34, "shape", short_name(shape), ui.selection[PAGE_LFO] == 2)
  draw_field(44, "rate", string.format("%.3fHz", lane.rate), ui.selection[PAGE_LFO] == 3)
  draw_field(54, "depth", tostring(lane.depth), ui.selection[PAGE_LFO] == 4)
end

function redraw()
  screen.clear()
  screen.level(10)
  screen.move(1, 8)
  screen.text(string.format("bento lfo %d/3", ui.page))

  if ui.page == PAGE_GLOBAL then
    draw_global_page()
  elseif ui.page == PAGE_ROUTE then
    draw_route_page()
  else
    draw_lfo_page()
  end

  screen.update()
  ui.dirty = false
  redraw_grid()
end

function enc(n, d)
  if n == 1 then
    ui.page = util.clamp(ui.page + encoder_delta(d), 1, ui.page_count)
    mark_dirty()
    return
  end

  if n == 2 then
    local max_by_page = {
      [PAGE_GLOBAL] = 2,
      [PAGE_ROUTE] = 4,
      [PAGE_LFO] = 4,
    }
    local max_fields = max_by_page[ui.page] or 1
    ui.selection[ui.page] = util.clamp(ui.selection[ui.page] + encoder_delta(d), 1, max_fields)
    mark_dirty()
    return
  end

  if n == 3 then
    local delta = encoder_delta(d)
    if ui.page == PAGE_GLOBAL then
      adjust_global(delta)
    elseif ui.page == PAGE_ROUTE then
      adjust_route(delta)
    elseif ui.page == PAGE_LFO then
      adjust_lfo(delta)
    end
    mark_dirty()
  end
end

function key(n, z)
  if z == 0 then
    return
  end

  if n == 2 then
    set_selected_lane(ui.selected_lane - 1)
    mark_dirty()
  elseif n == 3 then
    set_selected_lane(ui.selected_lane + 1)
    mark_dirty()
  end
end

function init()
  math.randomseed(os.time())

  for i = 1, LANE_COUNT do
    lanes[i] = default_lane()
    lanes[i].sh_value = (math.random() * 2) - 1
  end

  load_state()

  for i = 1, LANE_COUNT do
    ensure_lane_indices(lanes[i])
    reset_lane_history(lanes[i])
  end

  set_selected_lane(ui.selected_lane, false)

  set_output_device(ui.output_device)

  grid_device = connect_grid_device()
  if grid_device ~= nil then
    grid_device.key = function(x, y, z)
      local page_col = grid_device.cols or 16
      if page_col > 16 then
        page_col = 16
      end
      local value_col_min = GRID_VALUE_COL_MIN
      local value_col_max = math.min(GRID_VALUE_COL_MAX, page_col - 1)

      if x == page_col then
        if z == 1 and y >= 1 and y <= GRID_BANK_COUNT then
          clear_grid_hold()
          set_grid_bank(y)
          mark_dirty()
        end
        return
      end

      if x == 1 and z == 1 then
        local row = (y >= 1 and y <= GRID_BANK_ROWS) and y or 1
        local lane_index = ((ui.grid_bank - 1) * GRID_BANK_ROWS) + row
        if lane_index <= LANE_COUNT then
          set_selected_lane(lane_index)
          ui.page = PAGE_GLOBAL
          mark_dirty()
        end
        if grid_hold.active and grid_hold.row == row then
          clear_grid_hold()
        end
        return
      end

      if value_col_max >= value_col_min and x >= value_col_min and x <= value_col_max then
        local row = (y >= 1 and y <= GRID_BANK_ROWS) and y or 1
        local lane_index = ((ui.grid_bank - 1) * GRID_BANK_ROWS) + row
        if lane_index > LANE_COUNT then
          return
        end

        if z == 1 then
          if not grid_hold.active then
            start_grid_hold(lane_index, row, x, value_col_min, value_col_max)
          elseif grid_hold.active and grid_hold.row == row and grid_hold.lane_index == lane_index and x ~= grid_hold.base_col then
            if grid_hold.highest_col == nil or x > grid_hold.highest_col then
              grid_hold.highest_col = x
            end
          end
          return
        end

        if z == 0 and grid_hold.active and grid_hold.row == row and x == grid_hold.base_col then
          maybe_commit_grid_hold()
        end
      end
    end
  end

  start_redraw_timer()
  run_lfos()
  mark_dirty()
end

function cleanup()
  save_state()
  stop_lfos()
  stop_redraw_timer()
  if grid_device ~= nil then
    grid_device:all(0)
    grid_device:refresh()
    grid_device.key = nil
    grid_device = nil
  end
end
