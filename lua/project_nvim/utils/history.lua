local path = require("project_nvim.utils.path")
local uv = vim.loop
local M = {}
local is_windows = vim.fn.has("win32") or vim.fn.has("wsl")

M.recent_projects = nil -- projects from previous neovim sessions
M.session_projects = {} -- projects from current neovim session
M.project_name_map = {} -- 项目名称 与 项目路径 的映射
M.has_watch_setup = false

local function open_history(mode, callback)
  if callback ~= nil then -- async
    path.create_scaffolding(function(_, _)
      uv.fs_open(path.historyfile, mode, 438, callback)
    end)
  else -- sync
    path.create_scaffolding()
    return uv.fs_open(path.historyfile, mode, 438)
  end
end

local function open_project_name_map(mode, callback)
  if callback ~= nil then -- async
    path.create_scaffolding(function(_, _)
      uv.fs_open(path.project_name_map_file, mode, 438, callback)
    end)
  else -- sync
    path.create_scaffolding()
    return uv.fs_open(path.project_name_map_file, mode, 438)
  end
end

local function dir_exists(dir)
  local stat = uv.fs_stat(dir)
  if stat ~= nil and stat.type == "directory" then
    return true
  end
  return false
end

local function normalise_path(path_to_normalise)
  local normalised_path = path_to_normalise:gsub("\\", "/"):gsub("//", "/")

  if is_windows then
    normalised_path = normalised_path:sub(1, 1):lower() .. normalised_path:sub(2)
  end

  return normalised_path
end

local function delete_duplicates(tbl)
  local cache_dict = {}
  for _, v in ipairs(tbl) do
    local normalised_path = normalise_path(v)
    if cache_dict[normalised_path] == nil then
      cache_dict[normalised_path] = 1
    else
      cache_dict[normalised_path] = cache_dict[normalised_path] + 1
    end
  end

  local res = {}
  for _, v in ipairs(tbl) do
    local normalised_path = normalise_path(v)
    if cache_dict[normalised_path] == 1 then
      table.insert(res, normalised_path)
    else
      cache_dict[normalised_path] = cache_dict[normalised_path] - 1
    end
  end
  return res
end

function M.delete_project(project)
  for k, v in ipairs(M.recent_projects) do
    if v == project.value then
      M.recent_projects[k] = nil
    end
  end
end

local function write_project_name_map_to_file(mode)
  local name_map_file = open_project_name_map(mode)
  if name_map_file ~= nil then
    local map_out = ""
    for p_path, p_name in pairs(M.project_name_map) do
      map_out = map_out .. p_name .. " <<<<<>>>>> " .. p_path .. "\n"
    end
    uv.fs_write(name_map_file, map_out, -1)
    uv.fs_close(name_map_file)
  end
end

function M.rename_project(p_name, p_path)
  M.project_name_map[p_path] = p_name
  write_project_name_map_to_file("w")
end

local function deserialize_project_name_map(data_str)
  local project_name_map = {}
  for s in data_str:gmatch("[^\r\n]+") do
    local project_name, project_path = s:match("(.-)%s*<<<<<>>>>>%s*(.*)")

    if not path.is_excluded(project_path) and dir_exists(project_path) then
      project_name_map[project_path] = project_name
    end
  end

  M.project_name_map = project_name_map
end

local function deserialize_history(history_data)
  -- split data to table
  local projects = {}
  for s in history_data:gmatch("[^\r\n]+") do
    if not path.is_excluded(s) and dir_exists(s) then
      table.insert(projects, s)
    end
  end

  projects = delete_duplicates(projects)

  M.recent_projects = projects
end

local function setup_watch()
  -- Only runs once
  if M.has_watch_setup == false then
    M.has_watch_setup = true
    local event = uv.new_fs_event()
    if event == nil then
      return
    end
    event:start(path.projectpath, {}, function(err, _, events)
      if err ~= nil then
        return
      end
      if events["change"] then
        M.recent_projects = nil
        M.project_name_map = nil
        M.read_projects_from_history()
        M.init_project_name_map()
      end
    end)
  end
end

function M.init_project_name_map()
  open_project_name_map("r", function(_, fd)
    if fd ~= nil then
      uv.fs_fstat(fd, function(_, stat)
        if stat ~= nil then
          uv.fs_read(fd, stat.size, -1, function(_, data)
            uv.fs_close(fd, function(_, _) end)
            deserialize_project_name_map(data)
          end)
        end
      end)
    end
  end)
end

function M.read_projects_from_history()
  open_history("r", function(_, fd)
    setup_watch()
    if fd ~= nil then
      uv.fs_fstat(fd, function(_, stat)
        if stat ~= nil then
          uv.fs_read(fd, stat.size, -1, function(_, data)
            uv.fs_close(fd, function(_, _) end)
            deserialize_history(data)
          end)
        end
      end)
    end
  end)
end

local function sanitize_projects()
  local tbl = {}
  if M.recent_projects ~= nil then
    vim.list_extend(tbl, M.recent_projects)
    vim.list_extend(tbl, M.session_projects)
  else
    tbl = M.session_projects
  end

  tbl = delete_duplicates(tbl)

  local real_tbl = {}
  for _, dir in ipairs(tbl) do
    if dir_exists(dir) then
      table.insert(real_tbl, dir)
    end
  end

  return real_tbl
end

function M.get_recent_projects()
  return sanitize_projects()
end

function M.write_projects_to_history()
  -- Unlike read projects, write projects is synchronous
  -- because it runs when vim ends
  local mode = "w"
  if M.recent_projects == nil then
    mode = "a"
  end
  local file = open_history(mode)

  if file ~= nil then
    local res = sanitize_projects()

    -- Trim table to last 100 entries
    local len_res = #res
    local tbl_out
    if #res > 100 then
      tbl_out = vim.list_slice(res, len_res - 100, len_res)
    else
      tbl_out = res
    end

    -- Transform table to string
    local out = ""
    for _, v in ipairs(tbl_out) do
      out = out .. v .. "\n"
    end

    -- Write string out to file and close
    uv.fs_write(file, out, -1)
    uv.fs_close(file)
  end

  write_project_name_map_to_file(mode)
end

return M
