local script = arg and arg[0] or "tests/run.lua"
local root = script:match("^(.*)/tests/run%.lua$") or "."
local palette_path = "~/.local/state/omarchy/current/theme/colors.toml"
local token_path = "~/.local/state/omarchy/current/theme/vscode-theme.json"
local output_path = "{config}/themes/omarchy.json"

local function eq(got, want, label)
  assert(got == want, (label or "value") .. ": got " .. tostring(got) .. ", want " .. tostring(want))
end

local function contains(value, fragment, label)
  assert(value:find(fragment, 1, true), (label or "value") .. " does not contain " .. fragment)
end

local function sample_palette(extra)
  return table.concat({
    'foreground = "#eeeeee"',
    'background = "#101010"',
    'accent = "#ff8800"',
    'red = "#cc3333"',
    'green = "#33cc33"',
    'yellow = "#cccc33"',
    'blue = "#3333cc"',
    'magenta = "#cc33cc"',
    'cyan = "#33cccc"',
    extra or "",
  }, "\n")
end

local function load_plugin(palette, selected_theme, token_source, write_error, command_failures, without_notify)
  package.loaded.ttt = nil
  package.loaded["ttt.fs"] = nil
  package.loaded["ttt.settings"] = nil
  package.loaded["ttt.json"] = nil

  local files = { [palette_path] = palette }
  if token_source then files[token_path] = token_source end
  local mock = {
    files = files,
    selected_theme = selected_theme,
    write_error = write_error,
    command_failures = command_failures or 0,
    writes = {},
    commands = {},
    logs = {},
    notifications = {},
    settings_reads = {},
    reads = {},
  }

  local ttt = {
    register = function(config) mock.registration = config end,
    log = function(level, message) mock.logs[#mock.logs + 1] = { level, message } end,
    exec_command = function(id)
      mock.commands[#mock.commands + 1] = id
      if mock.command_failures > 0 then
        mock.command_failures = mock.command_failures - 1
        return false
      end
      return true
    end,
    set_timeout = function(ms, callback)
      mock.startup_timeout_ms = ms
      mock.startup_poll = callback
      return 2
    end,
    set_interval = function(ms, callback)
      mock.interval_ms = ms
      mock.poll = callback
      return 1
    end,
  }
  if not without_notify then
    ttt.notify = function(message, level)
      mock.notifications[#mock.notifications + 1] = { level, message }
    end
  end
  local fs = {
    read = function(path)
      mock.reads[#mock.reads + 1] = path
      local value = mock.files[path]
      if value == nil then return nil, mock.read_errors and mock.read_errors[path] or "not found" end
      return value
    end,
    write = function(path, content)
      if mock.write_error then return nil, mock.write_error end
      mock.writes[#mock.writes + 1] = { path = path, content = content }
      mock.snapshot = content
      return true
    end,
  }
  local settings = {
    get = function(key)
      mock.settings_reads[#mock.settings_reads + 1] = key
      assert(key == "theme", "plugin read unexpected setting " .. tostring(key))
      return mock.selected_theme
    end,
  }
  local json = {
    decode = function(source)
      if source == "invalid-json" then return nil, "invalid JSON" end
      local color = source:match("^token=(#[%x]+)$")
      if not color then return nil, "invalid JSON" end
      return { tokenColors = { { scope = "comment", settings = { foreground = color, fontStyle = "italic", background = "#000000" } } } }
    end,
    encode = function(theme)
      mock.theme = theme
      local token = theme.tokenColors and theme.tokenColors[1].settings.foreground or ""
      return table.concat({ theme.default.fg, theme.default.bg, theme.tabs.active.fg, theme.syntax.comment.fg, token }, "|")
    end,
  }

  package.preload.ttt = function() return ttt end
  package.preload["ttt.fs"] = function() return fs end
  package.preload["ttt.settings"] = function() return settings end
  package.preload["ttt.json"] = function() return json end
  dofile(root .. "/init.lua")
  eq(mock.startup_timeout_ms, 100, "deferred initial poll")
  mock.startup_poll()
  return mock
end

local valid_palette = sample_palette()
local running = load_plugin(valid_palette, "omarchy")
eq(#running.writes, 1, "initial snapshot write")
eq(running.writes[1].path, output_path, "snapshot path")
eq(#running.commands, 1, "reload selected theme")
eq(running.commands[1], "settings.reload", "reload command")
eq(running.interval_ms, 2000, "poll interval")
eq(#running.settings_reads, 1, "read selected setting after write")
eq(running.settings_reads[1], "theme", "setting key")
eq(running.registration and next(running.registration), nil, "no UI registration")
eq(#running.notifications, 0, "successful sync does not notify")
eq(running.theme.default.fg, "#eeeeee", "required foreground")
eq(running.theme.danger.fg, "#cc3333", "semantic danger")
assert(running.theme.syntax.comment.italic, "comment style should retain italic")
assert(running.theme.syntax.heading.bold, "heading style should retain bold")
local empty_group = nil
local function find_empty_group(value, path)
  for key, child in pairs(value) do
    if type(child) == "table" then
      if next(child) == nil then
        empty_group = empty_group or (path .. "." .. tostring(key))
      else
        find_empty_group(child, path .. "." .. tostring(key))
      end
    end
  end
end
find_empty_group(running.theme, "theme")
eq(empty_group, nil, "empty style group would encode as [] and be rejected by the host")
running.poll()
eq(#running.writes, 1, "unchanged source does not rewrite snapshot")
eq(#running.commands, 1, "unchanged source does not reload")
eq(#running.settings_reads, 1, "unchanged source does not read settings")

local invalid = load_plugin('foreground="#fff"\nbackground="#101010"', "omarchy")
eq(#invalid.writes, 0, "invalid palette is not written")
eq(#invalid.commands, 0, "invalid palette does not reload")
eq(#invalid.notifications, 1, "invalid palette notifies")
eq(invalid.notifications[1][1], "warn", "notification level")
contains(invalid.notifications[1][2], "Omarchy theme: ", "notification prefix")
local invalid_logs = #invalid.logs
invalid.poll()
eq(#invalid.logs, invalid_logs, "repeated invalid input is logged once")
eq(#invalid.notifications, 1, "repeated invalid input notifies once")
invalid.files[palette_path] = valid_palette
invalid.poll()
eq(#invalid.writes, 1, "corrected palette is retried")
eq(#invalid.commands, 1, "corrected palette reloads selected theme")

local malformed = load_plugin('foreground="#eeeeee"\nbackground="#101010"\nthis is not TOML', "omarchy")
eq(#malformed.writes, 0, "malformed TOML is not written")
local duplicate = load_plugin('foreground="#eeeeee"\nbackground="#101010"\nforeground="#ffffff"', "omarchy")
eq(#duplicate.writes, 0, "duplicate TOML keys are rejected")
local formatted = load_plugin('\r\n # comment\r\n foreground = "#eeeeee" # inline comment\r\n background = "#101010"\r\n', "other")
eq(#formatted.writes, 1, "whitespace, comments, and CRLF are accepted")
local invalid_optional = load_plugin('foreground="#eeeeee"\nbackground="#101010"\naccent="#ff8800"\nred="#invalid"', "other")
eq(invalid_optional.theme.danger.fg, invalid_optional.theme.tabs.active.fg, "invalid optional colors use fallback")
local low_contrast = load_plugin('foreground="#bebebe"\nbackground="#121212"\nmuted="#333333"', "other")
assert(low_contrast.theme.syntax.comment.fg ~= "#333333", "low contrast syntax color is corrected")
local typed_optional = load_plugin('foreground="#eeeeee"\nbackground="#101010"\nmode=true\nred=123', "other")
eq(typed_optional.theme.danger.fg, typed_optional.theme.tabs.active.fg, "valid non-string optional values use fallbacks")
local escaped_string = load_plugin([[foreground="#eeeeee"
background="#101010"
mode="dark\u0021"]], "other")
eq(#escaped_string.writes, 1, "valid Unicode TOML string escape is accepted")

local unselected = load_plugin(valid_palette, "other")
eq(#unselected.commands, 0, "unselected theme is not reloaded")
unselected.files[palette_path] = sample_palette('muted = "#777777"')
unselected.poll()
eq(#unselected.writes, 2, "changed palette updates static snapshot")
eq(#unselected.commands, 0, "changed palette does not change selected theme")

local alpha_token = load_plugin(valid_palette, "other", "token=#112233ff")
eq(alpha_token.theme.tokenColors[1].settings.foreground, "#737d87", "nine-digit token is normalized and contrast-corrected")
eq(alpha_token.theme.tokenColors[1].settings.fontStyle, "italic", "token font style is retained")
eq(alpha_token.theme.tokenColors[1].settings.background, nil, "unsupported token fields are dropped")

local optional = load_plugin(valid_palette, "other")
optional.files[token_path] = "token=#66aaff"
optional.poll()
eq(#optional.writes, 2, "optional token file creation updates snapshot")
assert(optional.theme.tokenColors, "valid token file is included")
local first_token = optional.theme.tokenColors[1].settings.foreground
optional.files[token_path] = "token=#ff66aa"
optional.poll()
eq(#optional.writes, 3, "optional token change updates snapshot")
assert(optional.theme.tokenColors[1].settings.foreground ~= first_token, "changed token color is reflected")
optional.files[token_path] = nil
optional.poll()
eq(#optional.writes, 4, "optional token removal updates snapshot")
eq(optional.theme.tokenColors, nil, "removed token file falls back to palette-only")
optional.files[token_path] = "invalid-json"
optional.poll()
eq(#optional.writes, 4, "invalid optional token file falls back without redundant rewrite")
eq(optional.theme.tokenColors, nil, "invalid optional token file is ignored")

local unavailable = load_plugin(valid_palette, "omarchy")
local retained_snapshot = unavailable.snapshot
unavailable.files[palette_path] = nil
unavailable.poll()
eq(unavailable.snapshot, retained_snapshot, "missing source retains static snapshot")
eq(#unavailable.writes, 1, "missing source does not write or delete snapshot")
eq(#unavailable.commands, 1, "missing source does not reload")
unavailable.read_errors = { [palette_path] = "access denied" }
unavailable.files[palette_path] = nil
unavailable.poll()
eq(unavailable.snapshot, retained_snapshot, "denied source retains static snapshot")
eq(#unavailable.writes, 1, "denied source does not mutate output")
unavailable.files[palette_path] = valid_palette:gsub('accent = "#ff8800"', 'accent = "#00aaff"')
unavailable.poll()
eq(#unavailable.writes, 2, "changed active current target is detected on next read")
for _, path in ipairs(unavailable.reads) do
  assert(path == palette_path or path == token_path, "plugin read outside declared Omarchy paths: " .. path)
end

local retry_reload = load_plugin(valid_palette, "omarchy", nil, nil, 1)
eq(#retry_reload.writes, 1, "failed reload follows a successful snapshot write")
eq(#retry_reload.commands, 1, "selected theme reload attempted")
retry_reload.poll()
eq(#retry_reload.writes, 1, "reload retry does not rewrite snapshot")
eq(#retry_reload.commands, 2, "failed reload is retried on the next poll")
eq(#retry_reload.settings_reads, 2, "reload retry checks the selected theme")

local retry_write = load_plugin(valid_palette, "omarchy", nil, "themes directory missing")
eq(#retry_write.writes, 0, "failed output write has no success")
eq(#retry_write.commands, 0, "failed output write does not reload")
eq(#retry_write.settings_reads, 0, "failed output write does not read settings")
contains(retry_write.logs[1][2], "mkdir -p ~/.config/ttt/themes", "missing directory guidance")
eq(#retry_write.notifications, 1, "failed output write notifies")
contains(retry_write.notifications[1][2], "mkdir -p ~/.config/ttt/themes", "notification guidance")
retry_write.write_error = nil
retry_write.poll()
eq(#retry_write.writes, 1, "failed output write retries")
eq(#retry_write.commands, 1, "successful retry reloads selected theme")
eq(#retry_write.settings_reads, 1, "successful output reads selected theme once")
eq(#retry_write.notifications, 1, "successful retry does not notify again")

local no_notify = load_plugin('foreground="#fff"\nbackground="#101010"', "omarchy", nil, nil, 0, true)
eq(#no_notify.logs, 1, "host without ttt.notify still logs")

print("omarchy theme plugin tests passed")
