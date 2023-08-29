local M = {}

local function wrap(text, line_width)
    local out_s = ""
    local space_left = line_width
    for tok in text:gmatch("[^ ]+") do
        if #tok + 1 > space_left then
            out_s = out_s .. "\n" .. tok
            space_left = line_width - #tok
        else
            out_s = out_s .. tok .. " "

            space_left = space_left - (#tok + 1)
        end
    end
    return out_s
end

local HIGHLIGHTS = {
    native = {
        [vim.diagnostic.severity.ERROR] = "DiagnosticVirtualTextError",
        [vim.diagnostic.severity.WARN] = "DiagnosticVirtualTextWarn",
        [vim.diagnostic.severity.INFO] = "DiagnosticVirtualTextInfo",
        [vim.diagnostic.severity.HINT] = "DiagnosticVirtualTextHint",
    },
    coc = {
        [vim.diagnostic.severity.ERROR] = "CocErrorVirtualText",
        [vim.diagnostic.severity.WARN] = "CocWarningVirtualText",
        [vim.diagnostic.severity.INFO] = "CocInfoVirtualText",
        [vim.diagnostic.severity.HINT] = "CocHintVirtualText",
    },
}

-- These don't get copied, do they? We only pass around and compare pointers, right?
local SPACE = "space"
local DIAGNOSTIC = "diagnostic"
local OVERLAP = "overlap"
local BLANK = "blank"

---Returns the distance between two columns in cells.
---
---Some characters (like tabs) take up more than one cell. A diagnostic aligned
---under such characters needs to account for that and add that many spaces to
---its left.
---
---@return integer
local function distance_between_cols(bufnr, lnum, start_col, end_col)
    local lines = vim.api.nvim_buf_get_lines(bufnr, lnum, lnum + 1, false)
    if vim.tbl_isempty(lines) then
        -- This can only happen is the line is somehow gone or out-of-bounds.
        return 1
    end

    local sub = string.sub(lines[1], start_col, end_col)
    return vim.fn.strdisplaywidth(sub, 0) -- these are indexed starting at 0
end

---@param namespace number
---@param bufnr number
---@param diagnostics table
---@param opts boolean
---@param source 'native'|'coc'|nil If nil, defaults to 'native'.
function M.show(namespace, bufnr, diagnostics, opts, source)
    vim.validate({
        namespace = { namespace, "n" },
        bufnr = { bufnr, "n" },
        diagnostics = {
            diagnostics,
            vim.tbl_islist,
            "a list of diagnostics",
        },
        opts = { opts, "t", true },
    })

    table.sort(diagnostics, function(a, b)
        if a.lnum ~= b.lnum then
            return a.lnum < b.lnum
        else
            return a.col < b.col
        end
    end)

    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
    if #diagnostics == 0 then
        return
    end
    local highlight_groups = HIGHLIGHTS[source or "native"]

    local scroll_offset = {
        x = vim.fn.winsaveview().leftcol,
        y = vim.fn.winsaveview().topline,
    }
    local textoff = vim.fn.getwininfo(vim.fn.win_getid())[1].textoff
    local winwidth = vim.fn.getwininfo(vim.fn.win_getid())[1].width
    local buf_width = winwidth - textoff

    -- This loop reads line by line, and puts them into stacks with some
    -- extra data, since rendering each line will require understanding what
    -- is beneath it.
    local line_stacks = {}
    local prev_lnum = -1
    local prev_col = scroll_offset.x
    for _, diagnostic in ipairs(diagnostics) do
        if (
                (diagnostic.col <= scroll_offset.x + buf_width) and
                (scroll_offset.x <= diagnostic.end_col)
        ) then
            local col = math.min(math.max(scroll_offset.x, diagnostic.col), scroll_offset.x + buf_width)

            if line_stacks[diagnostic.lnum] == nil then
                line_stacks[diagnostic.lnum] = {}
            end


            local stack = line_stacks[diagnostic.lnum]

            if diagnostic.lnum ~= prev_lnum then
                local delta = distance_between_cols(bufnr, diagnostic.lnum, scroll_offset.x, col)
                table.insert(stack, { SPACE, string.rep(" ", delta) })
            elseif col ~= prev_col then
                -- Clarification on the magic numbers below:
                -- +1: indexing starting at 0 in one API but at 1 on the other.
                -- -1: for non-first lines, the previous col is already drawn.
                local delta = distance_between_cols(bufnr, diagnostic.lnum, prev_col + 1, col)
                table.insert(
                    stack,
                    { SPACE, string.rep(" ", delta - 1) }
                )
            else
                table.insert(stack, { OVERLAP, diagnostic.severity })
            end

            if diagnostic.message:find("^%s*$") then
                table.insert(stack, { BLANK, diagnostic })
            else
                table.insert(stack, { DIAGNOSTIC, diagnostic })
            end

            prev_lnum = diagnostic.lnum
            prev_col = col
        end

        prev_lnum = diagnostic.lnum
        prev_col = diagnostic.col
    end


    for lnum, lelements in pairs(line_stacks) do
        local virt_lines = {}

        -- We read in the order opposite to insertion because the last
        -- diagnostic for a real line, is rendered upstairs from the
        -- second-to-last, and so forth from the rest.
        for i = #lelements, 1, -1 do -- last element goes on top
            if lelements[i][1] == DIAGNOSTIC then
                local diagnostic = lelements[i][2]

                local left = {}
                local overlap = false
                local multi = 0

                -- Iterate the stack for this line to find elements on the left.
                for j = 1, i - 1 do
                    local type = lelements[j][1]
                    local data = lelements[j][2]
                    if type == SPACE then
                        if multi == 0 then
                            table.insert(left, { data, "" })
                        else
                            table.insert(left, { string.rep("─", data:len()), highlight_groups[diagnostic.severity] })
                        end
                    elseif type == DIAGNOSTIC then
                        -- If an overlap follows this, don't add an extra column.
                        if lelements[j + 1][1] ~= OVERLAP then
                            table.insert(left, { "│", highlight_groups[data.severity] })
                        end
                        overlap = false
                    elseif type == BLANK then
                        if multi == 0 then
                            table.insert(left, { "└", highlight_groups[data.severity] })
                        else
                            table.insert(left, { "┴", highlight_groups[data.severity] })
                        end
                        multi = multi + 1
                    elseif type == OVERLAP then
                        overlap = true
                    end
                end

                local center_symbol
                if overlap and multi > 0 then
                    center_symbol = "┼"
                elseif overlap then
                    center_symbol = "├"
                elseif multi > 0 then
                    center_symbol = "┴"
                else
                    center_symbol = "└"
                end
                -- local center_text =
                local center = {
                    { string.format("%s%s", center_symbol, "──── "), highlight_groups[diagnostic.severity] },
                }

                -- TODO: We can draw on the left side if and only if:
                -- a. Is the last one stacked this line.
                -- b. Has enough space on the left.
                -- c. Is just one line.
                -- d. Is not an overlap.

                local col = math.min(math.max(scroll_offset.x, diagnostic.col), scroll_offset.x + buf_width)
                local message = wrap(diagnostic.message .. string.format(" %d->%d", col, diagnostic.end_col),
                    buf_width + scroll_offset.x - (col + 6) - 1)

                for msg_line in message:gmatch("([^\n]+)") do
                    local vline = {}
                    vim.list_extend(vline, left)
                    vim.list_extend(vline, center)
                    vim.list_extend(vline, { { msg_line, highlight_groups[diagnostic.severity] } })

                    table.insert(virt_lines, vline)

                    -- Special-case for continuation lines:
                    if overlap then
                        center = { { "│", highlight_groups[diagnostic.severity] }, { "     ", "" } }
                    else
                        center = { { "      ", "" } }
                    end
                end
            end
        end

        vim.api.nvim_buf_set_extmark(bufnr, namespace, lnum, 0, { virt_lines = virt_lines })
    end
end

---@param namespace number
---@param bufnr number
function M.hide(namespace, bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
end

return M
