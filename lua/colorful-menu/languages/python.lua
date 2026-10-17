local config = require("colorful-menu").config
local Kind = require("colorful-menu").Kind
local utils = require("colorful-menu.utils")

local M = {}

---@param completion_item lsp.CompletionItem
---@return CMHighlights
local function pylsp(completion_item)
    local path = vim.tbl_get(completion_item, "labelDetails", "description")
    local hls = require("colorful-menu.languages.default").default_highlight(
        completion_item,
        path,
        "python",
        config.ls.pylsp.extra_info_hl
    )
    if hls.text ~= nil and (completion_item.kind == Kind.Function or completion_item.kind == Kind.Method) then
        local s, e = string.find(hls.text, "%b()")
        if s ~= nil and e ~= nil then
            table.insert(hls.highlights, {
                config.ls.pylsp.arguments_hl,
                range = { s - 1, e },
            })
        end
    end
    return hls
end

-- Call `fn(i, c)` for each character of `s` from `init` that is not nested inside
-- brackets or string literals (closing brackets included), until it returns true.
---@param s string
---@param fn fun(i: integer, c: string): boolean?
---@param init? integer
---@param angle? boolean also treat `<...>` as brackets
local function scan_top_level(s, fn, init, angle)
    local depth, quote, escaped = 0, nil, false
    for i = init or 1, #s do
        local c = s:sub(i, i)
        if quote then
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == quote then
                quote = nil
            end
        elseif c == '"' or c == "'" then
            quote = c
        elseif c == "(" or c == "[" or c == "{" or (angle and c == "<") then
            depth = depth + 1
        else
            if c == ")" or c == "]" or c == "}" or (angle and c == ">") then
                depth = depth - 1
            end
            if depth == 0 and fn(i, c) then
                return
            end
        end
    end
end

-- Split `s` on top-level commas.
---@param s string
---@return string[]
local function split_top_level(s)
    local parts, start = {}, 1
    scan_top_level(s, function(i, c)
        if c == "," then
            table.insert(parts, vim.trim(s:sub(start, i - 1)))
            start = i + 1
        end
    end)
    table.insert(parts, vim.trim(s:sub(start)))
    return parts
end

-- Index of the bracket closing the one at `s[i]`.
---@param s string
---@param i integer
---@return integer?
local function closing_bracket(s, i)
    local close
    scan_top_level(s, function(j, c)
        close = (c == ")" or c == "]") and j or nil
        return true
    end, i)
    return close
end

-- Split ty's display of a callable type into the parameters (with type parameters,
-- if any), the return type and the number of other overloads, e.g.
--   def foo[T](x: T) -> T                           => [T](x: T), T, 0
--   bound method Foo.bar(y: str) -> int             => (y: str), int, 0
--   bound method type[dict[str, int]].baz() -> None => (), None, 0
--   (x: int) -> None                                => (x: int), None, 0
--   Overload[(a: int) -> int, (a: str) -> str]      => (a: int), int, 1
-- Returns nil for anything else, e.g. `(() -> int) | None` or `<method-wrapper ...>`.
---@param detail string
---@return string?, string?, integer?
local function ty_signature(detail)
    local overloads = 0
    local inner = detail:match("^Overload%[(.*)%]$")
    if inner then
        local parts = split_top_level(inner)
        detail, overloads = parts[1], #parts - 1
    end

    local sig
    if detail:match("^[%(%[]") then
        sig = detail
    elseif vim.startswith(detail, "def ") then
        sig = detail:match("^def [^%s%(%[]+([%(%[].*)$")
    elseif vim.startswith(detail, "bound method ") then
        -- The receiver can be anything, e.g. `type[dict[str, int]]` or `<class 'Color'>`.
        scan_top_level(detail, function(i, c)
            if c == "." then
                sig = detail:match("^%.[^%s%.%(%[]+([%(%[].*)$", i)
                return true
            end
        end, #"bound method " + 1, true)
    end
    if sig == nil then
        return nil
    end

    local params_end = sig:sub(1, 1) == "[" and closing_bracket(sig, 1) or 0
    if params_end == nil or sig:sub(params_end + 1, params_end + 1) ~= "(" then
        return nil
    end
    params_end = closing_bracket(sig, params_end + 1)
    local ret = params_end and sig:match("^%s*%->%s*(.+)$", params_end + 1)
    if ret == nil then
        return nil
    end
    return sig:sub(1, params_end), ret, overloads
end

-- `text` highlighted with `hl_group`, if any.
---@param text string
---@param hl_group? string
---@return CMHighlights
local function span(text, hl_group)
    return { text = text, highlights = hl_group and { { hl_group, range = { 0, #text } } } or {} }
end

-- Highlight a type expression, e.g. `list[str] | None`.
---@param type_expr string
---@param ls string
---@return CMHighlights
local function highlight_type(type_expr, ls)
    local source = "x: " .. type_expr
    return utils.highlight_range(source, ls, 3, #source)
end

-- Append `other` to the end of `item`, shifting its highlights.
---@param item CMHighlights
---@param other CMHighlights
---@return CMHighlights
local function append(item, other)
    local offset = #item.text
    for _, hl in ipairs(other.highlights) do
        table.insert(item.highlights, { hl[1], range = { hl.range[1] + offset, hl.range[2] + offset } })
    end
    item.text = item.text .. other.text
    return item
end

-- Dim ty's `Unknown` (an unannotated, uninferable type) after the first `start` bytes.
---@param item CMHighlights
---@param start integer
---@return CMHighlights
local function dim_unknown(item, start)
    for s, e in item.text:sub(start + 1):gmatch("()%f[%w_]Unknown%f[^%w_]()") do
        s, e = start + s - 1, start + e - 1
        for i = #item.highlights, 1, -1 do
            local r = item.highlights[i].range
            if r[1] < e and r[2] > s then
                table.remove(item.highlights, i)
            end
        end
        table.insert(item.highlights, { config.ls.ty.extra_info_hl, range = { s, e } })
    end
    return item
end

---@param completion_item lsp.CompletionItem
---@param ls string
---@return CMHighlights
local function ty(completion_item, ls)
    local opts = config.ls.ty
    local label = completion_item.label
    local kind = completion_item.kind
    local import_suffix = vim.tbl_get(completion_item, "labelDetails", "detail")
    local detail = completion_item.detail or vim.tbl_get(completion_item, "labelDetails", "description")
    if type(detail) ~= "string" or detail == "" or detail:find("[\n\r]") then
        detail = nil
    end

    -- Without labelDetails support, ty appends the import to the label.
    if import_suffix == nil then
        local name, suffix = label:match("^(.-)( %(import [^)]+%))$")
        if name then
            label, import_suffix = name, suffix
        end
    end

    -- Enum members (reported as Enum): `RED` with type `Literal[Color.RED]`.
    local enum_member = kind == Kind.Enum and detail and detail:match("^Literal%[[^%[%]]+%.[^%[%]]+%]$")
    -- String literals, e.g. TypedDict keys: `alpha` with type `Literal["alpha"]`.
    local string_literal = detail == ('Literal["%s"]'):format(label) or detail == ("Literal['%s']"):format(label)

    local name_hl
    if label:sub(-1) == "=" then
        -- Keyword argument: `func(alpha=`
        name_hl = utils.hl_exist_or("@variable.parameter", "@variable", "python")
    elseif enum_member then
        name_hl = utils.hl_exist_or("@lsp.type.enumMember", "@constant", "python")
    elseif string_literal then
        name_hl = "@string"
    elseif kind == Kind.Struct and not (detail and vim.startswith(detail, "<class ")) then
        -- ty reports attributes and properties as Struct.
        name_hl = utils.hl_by_kind(Kind.Property, "python")
    else
        name_hl = utils.hl_by_kind(kind, "python")
    end
    local item = span(label, name_hl)

    -- Unimported symbol: `name     module` or `name (import module)`
    if import_suffix and import_suffix ~= "" then
        local module = import_suffix:match("^ %(import (.+)%)$")
        if module == label then
            -- `import calendar` itself, nothing to add.
            return item
        elseif module and opts.align_type_to_right then
            append(item, span(utils.align_spaces_bell(label, module)))
            import_suffix = module
        end
        return append(item, span(import_suffix, opts.extra_info_hl))
    end

    -- The label says it all for keywords (`True` with type `Literal[True]`), classes
    -- (`<class 'Foo'>`), modules (`<module 'os'>`), etc.
    if
        kind == Kind.Keyword
        or enum_member
        or string_literal
        or detail == nil
        or detail == "Unknown"
        or detail:match("^<.*>$")
    then
        return item
    end

    local params, ret, overloads = ty_signature(detail)
    if params == nil then
        -- Variables, attributes, properties: `x                 int` or `x: int`
        if opts.align_type_to_right then
            append(item, span(utils.align_spaces_bell(label, detail)))
        else
            append(item, span(":", "@punctuation.delimiter.python"))
            append(item, span(" "))
        end
        return dim_unknown(append(item, highlight_type(detail, ls)), #label)
    end

    if ret == "Unknown" then
        ret = nil
    elseif not opts.align_type_to_right then
        -- foo(x: int) -> str
        params, ret = params .. " -> " .. ret, nil
    end

    local source = "def " .. label .. params .. ": ..."
    item = utils.highlight_range(source, ls, 4, 4 + #label + #params)
    -- Drop the highlights of the name (the parser colors dunder names as builtin
    -- constants) and past the end (the trailing `:` of the source).
    item.highlights = vim.tbl_filter(function(hl)
        return hl.range[1] >= #label and hl.range[1] < #item.text
    end, item.highlights)
    if kind ~= Kind.Method and kind ~= Kind.Constructor then
        name_hl = utils.hl_by_kind(Kind.Function, "python")
    end
    -- First, as native completion only uses the first highlight.
    table.insert(item.highlights, 1, { name_hl, range = { 0, #label } })

    if overloads > 0 then
        -- Only if it fits, a truncated hint would just be noise.
        local hint = (" (+%d overload%s)"):format(overloads, overloads > 1 and "s" or "")
        -- The return type is separated by at least 3 spaces.
        local width = vim.fn.strdisplaywidth(item.text .. hint) + (ret and vim.fn.strdisplaywidth(ret) + 3 or 0)
        local max_width = utils.max_width()
        if max_width <= 0 or width <= max_width then
            append(item, span(hint, opts.extra_info_hl))
        end
    end
    if ret then
        -- foo(x: int)                 str
        append(item, span(utils.align_spaces_bell(item.text, ret)))
        append(item, highlight_type(ret, ls))
    end
    return dim_unknown(item, #label)
end

---@param completion_item lsp.CompletionItem
---@param ls string
---@return CMHighlights
function M.py(completion_item, ls)
    if ls == "pylsp" then
        return pylsp(completion_item)
    elseif ls == "ty" then
        return ty(completion_item, ls)
    else
        local path = vim.tbl_get(completion_item, "labelDetails", "description")
        return require("colorful-menu.languages.default").default_highlight(
            completion_item,
            path,
            "python",
            config.ls.basedpyright.extra_info_hl
        )
    end
end

return M
