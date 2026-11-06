-- Adapted from arusuki/wilder.nvim, wilder-fzf/lua/wilder_fzf/highlighter.lua
-- Source blob: 3cd0e84504c1b2970b792867054fe86fcac824e0
-- Retains fzf-v2-style scoring/backtracking and the bounded v1 fallback.
-- Extended operators are omitted: our backend uses --no-extended.
-- Spans are zero-based UTF-8 {start, end} offsets into the candidate label.
--[[
MIT License

Copyright (c) 2019 Jit Yao Yap

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
]]

local M = {}

local char_white = 1
local char_non_word = 2
local char_delimiter = 3
local char_lower = 4
local char_upper = 5
local char_letter = 6
local char_number = 7

local score_match = 16
local score_gap_start = -3
local score_gap_extension = -1
local bonus_boundary = score_match / 2
local bonus_non_word = score_match / 2
local bonus_camel_123 = bonus_boundary + score_gap_extension
local bonus_consecutive = -(score_gap_start + score_gap_extension)
local bonus_first_char_multiplier = 2

local function iter_chars(text, fn)
  local count = vim.fn.strchars(text or "")
  for index = 0, count - 1 do
    fn(vim.fn.strcharpart(text, index, 1))
  end
end

local function contains_upper(text)
  local has_upper = false
  iter_chars(text, function(char)
    if vim.fn.toupper(char) == char and vim.fn.tolower(char) ~= char then
      has_upper = true
    end
  end)
  return has_upper
end

local function case_sensitive_for(query, opts)
  if opts.case_sensitive ~= nil then
    return opts.case_sensitive
  end
  return contains_upper(query)
end

local function scheme_config(scheme)
  if scheme == "path" then
    return {
      boundary_white = bonus_boundary,
      boundary_delimiter = bonus_boundary + 1,
      initial_class = char_delimiter,
      delimiters = "/",
    }
  elseif scheme == "history" then
    return {
      boundary_white = bonus_boundary,
      boundary_delimiter = bonus_boundary,
      initial_class = char_white,
      delimiters = "/,:;|",
    }
  end

  return {
    boundary_white = bonus_boundary + 2,
    boundary_delimiter = bonus_boundary + 1,
    initial_class = char_white,
    delimiters = "/,:;|",
  }
end

local function is_delimiter(char, config)
  return config.delimiters:find(char, 1, true) ~= nil
end

local function char_class(char, config)
  if char:match("^[a-z]$") then
    return char_lower
  elseif char:match("^[A-Z]$") then
    return char_upper
  elseif char:match("^[0-9]$") then
    return char_number
  elseif char:match("^%s$") then
    return char_white
  elseif is_delimiter(char, config) then
    return char_delimiter
  end

  local lower = vim.fn.tolower(char)
  local upper = vim.fn.toupper(char)
  if lower ~= upper then
    if char == lower then
      return char_lower
    elseif char == upper then
      return char_upper
    end
    return char_letter
  end

  return char_non_word
end

local function bonus_for(prev_class, class, config)
  if class >= char_non_word then
    if prev_class == char_white then
      return config.boundary_white
    elseif prev_class == char_delimiter then
      return config.boundary_delimiter
    elseif prev_class == char_non_word then
      return bonus_boundary
    end
  end

  if (prev_class == char_lower and class == char_upper) or (prev_class ~= char_number and class == char_number) then
    return bonus_camel_123
  end

  if class == char_non_word or class == char_delimiter then
    return bonus_non_word
  elseif class == char_white then
    return config.boundary_white
  end

  return 0
end

local function split_chars(text, case_sensitive, config)
  local chars = {}
  local byte_start = 0

  iter_chars(text, function(raw)
    local byte_len = #raw
    local class = char_class(raw, config)
    local match = raw
    if not case_sensitive then
      match = vim.fn.tolower(raw)
    end

    chars[#chars + 1] = {
      raw = raw,
      match = match,
      class = class,
      byte_start = byte_start,
      byte_len = byte_len,
    }
    byte_start = byte_start + byte_len
  end)

  return chars
end

local function split_pattern(pattern, case_sensitive)
  local chars = {}
  iter_chars(pattern, function(char)
    if not case_sensitive then
      char = vim.fn.tolower(char)
    end
    chars[#chars + 1] = char
  end)
  return chars
end

local function max3(a, b, c)
  return math.max(a, math.max(b, c))
end

local function has_subsequence(chars, pattern)
  local pidx = 1
  for _, char in ipairs(chars) do
    if char.match == pattern[pidx] then
      pidx = pidx + 1
      if pidx > #pattern then
        return true
      end
    end
  end
  return #pattern == 0
end

local function fuzzy_positions_v1(chars, pattern, config)
  if #pattern == 0 then
    return {}
  end

  local pidx = 1
  local start_idx = nil
  local end_idx = nil

  for index, char in ipairs(chars) do
    if char.match == pattern[pidx] then
      start_idx = start_idx or index
      pidx = pidx + 1
      if pidx > #pattern then
        end_idx = index
        break
      end
    end
  end

  if start_idx == nil or end_idx == nil then
    return nil
  end

  pidx = #pattern
  for index = end_idx, start_idx, -1 do
    if chars[index].match == pattern[pidx] then
      pidx = pidx - 1
      if pidx == 0 then
        start_idx = index
        break
      end
    end
  end

  local positions = {}
  pidx = 1
  for index = start_idx, end_idx do
    local char = chars[index]
    if char.match == pattern[pidx] then
      positions[#positions + 1] = index
      pidx = pidx + 1
      if pidx > #pattern then
        break
      end
    end
  end

  return positions
end

local function fuzzy_positions_v2(chars, pattern, config)
  local m = #pattern
  local n = #chars
  if m == 0 then
    return {}
  elseif m > n then
    return nil
  elseif m > 1000 or m * n > 200000 then
    return fuzzy_positions_v1(chars, pattern, config)
  end

  if not has_subsequence(chars, pattern) then
    return nil
  end

  local h0 = {}
  local c0 = {}
  local bonuses = {}
  local first = {}
  local pidx = 1
  local pchar0 = pattern[1]
  local pchar = pattern[1]
  local last_idx = 0
  local prev_h0 = 0
  local prev_class = config.initial_class
  local in_gap = false
  local max_score = 0
  local max_score_pos = 1

  for index, char in ipairs(chars) do
    local bonus = bonus_for(prev_class, char.class, config)
    bonuses[index] = bonus
    prev_class = char.class

    if char.match == pchar then
      if pidx <= m then
        first[pidx] = index
        pidx = pidx + 1
        pchar = pattern[math.min(pidx, m)]
      end
      last_idx = index
    end

    if char.match == pchar0 then
      local score = score_match + bonus * bonus_first_char_multiplier
      h0[index] = score
      c0[index] = 1
      if m == 1 and score > max_score then
        max_score = score
        max_score_pos = index
        if bonus >= bonus_boundary then
          break
        end
      end
      in_gap = false
    else
      if in_gap then
        h0[index] = math.max(prev_h0 + score_gap_extension, 0)
      else
        h0[index] = math.max(prev_h0 + score_gap_start, 0)
      end
      c0[index] = 0
      in_gap = true
    end

    prev_h0 = h0[index]
  end

  if pidx <= m then
    return nil
  end

  if m == 1 then
    return { max_score_pos }
  end

  local f0 = first[1]
  local h = {}
  local consecutive = {}

  h[1] = {}
  consecutive[1] = {}
  for index = f0, last_idx do
    h[1][index] = h0[index] or 0
    consecutive[1][index] = c0[index] or 0
  end

  for row = 2, m do
    local f = first[row]
    local pchar_row = pattern[row]
    local row_h = {}
    local row_c = {}
    h[row] = row_h
    consecutive[row] = row_c
    in_gap = false

    for col = f, last_idx do
      local left = col == f and 0 or (row_h[col - 1] or 0)
      local s2
      if in_gap then
        s2 = left + score_gap_extension
      else
        s2 = left + score_gap_start
      end

      local s1 = 0
      local chunk_len = 0
      if chars[col].match == pchar_row then
        local diag = (h[row - 1] and h[row - 1][col - 1]) or 0
        s1 = diag + score_match
        local bonus = bonuses[col]
        chunk_len = ((consecutive[row - 1] and consecutive[row - 1][col - 1]) or 0) + 1

        if chunk_len > 1 then
          local first_bonus = bonuses[col - chunk_len + 1] or 0
          if bonus >= bonus_boundary and bonus > first_bonus then
            chunk_len = 1
          else
            bonus = max3(bonus, bonus_consecutive, first_bonus)
          end
        end

        if s1 + bonus < s2 then
          s1 = s1 + bonuses[col]
          chunk_len = 0
        else
          s1 = s1 + bonus
        end
      end

      row_c[col] = chunk_len
      in_gap = s1 < s2
      local score = math.max(s1, s2, 0)
      if row == m and score > max_score then
        max_score = score
        max_score_pos = col
      end
      row_h[col] = score
    end
  end

  local positions = {}
  local row = m
  local col = max_score_pos
  local prefer_match = true

  while row >= 1 and col >= f0 do
    local score = (h[row] and h[row][col]) or 0
    local s1 = 0
    local s2 = 0

    if row > 1 and col >= first[row] then
      s1 = (h[row - 1] and h[row - 1][col - 1]) or 0
    end
    if col > first[row] then
      s2 = (h[row] and h[row][col - 1]) or 0
    end

    if score > s1 and (score > s2 or (score == s2 and prefer_match)) then
      positions[#positions + 1] = col
      if row == 1 then
        break
      end
      row = row - 1
    end

    local next_c = 0
    if row + 1 <= m then
      next_c = (consecutive[row + 1] and consecutive[row + 1][col + 1]) or 0
    end
    prefer_match = ((consecutive[row] and consecutive[row][col]) or 0) > 1 or next_c > 0
    col = col - 1
  end

  if #positions ~= m then
    return fuzzy_positions_v1(chars, pattern, config)
  end

  local reversed = {}
  for index = #positions, 1, -1 do
    reversed[#reversed + 1] = positions[index]
  end
  return reversed
end

local function positions_to_spans(chars, positions)
  if positions == nil or #positions == 0 then
    return positions
  end

  local spans = {}
  local current_start = nil
  local current_end = nil

  for _, position in ipairs(positions) do
    local char = chars[position]
    if char ~= nil then
      local start_byte = char.byte_start
      local end_byte = start_byte + char.byte_len
      if current_start == nil then
        current_start = start_byte
        current_end = end_byte
      elseif start_byte == current_end then
        current_end = end_byte
      else
        spans[#spans + 1] = { current_start, current_end }
        current_start = start_byte
        current_end = end_byte
      end
    end
  end

  if current_start ~= nil then
    spans[#spans + 1] = { current_start, current_end }
  end

  return spans
end

function M.spans(text, query, case)
  if text == nil or query == "" then
    return {}
  end
  local opts = {}
  if case == "--ignore-case" then
    opts.case_sensitive = false
  elseif case == "--no-ignore-case" then
    opts.case_sensitive = true
  end
  local sensitive = case_sensitive_for(query, opts)
  local config = scheme_config("default")
  local chars = split_chars(text, sensitive, config)
  local pattern = split_pattern(query, sensitive)
  return positions_to_spans(chars, fuzzy_positions_v2(chars, pattern, config)) or {}
end

return M
