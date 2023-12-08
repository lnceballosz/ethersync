local utils = require("utils")

-- Used to store the changedtick of the buffer when we make changes to it.
-- We do this to avoid infinite loops, where we make a change, which would
-- trigger normally an "on_bytes" event.
--
-- TODO: how big will this list get? should we optimize it?
local ignored_ticks = {}

local ns_id = vim.api.nvim_create_namespace("Ethersync")
local virtual_cursor

local client

local daemonRevision = 0
local editorRevision = 0

-- Used to remember the previous content of the buffer, so that we can
-- calculate the difference between the previous and the current content.
local previousContent

local function ignoreNextUpdate()
    local nextTick = vim.api.nvim_buf_get_changedtick(0)
    ignored_ticks[nextTick] = true
end

-- Insert a string into the current buffer at a specified UTF-16 code unit index.
local function insert(index, content)
    local row, col = utils.UTF16CodeUnitOffsetToRowCol(index)
    ignoreNextUpdate()
    vim.api.nvim_buf_set_text(0, row, col, row, col, vim.split(content, "\n"))
end

-- Delete a string from the current buffer at a specified UTF-16 code unit index.
local function delete(index, length)
    local row, col = utils.UTF16CodeUnitOffsetToRowCol(index)
    local rowEnd, colEnd = utils.UTF16CodeUnitOffsetToRowCol(index + length)
    ignoreNextUpdate()
    vim.api.nvim_buf_set_text(0, row, col, rowEnd, colEnd, { "" })
end

local function createCursor()
    local row = 0
    local col = 0
    virtual_cursor = vim.api.nvim_buf_set_extmark(0, ns_id, row, col, {
        hl_mode = "combine",
        hl_group = "TermCursor",
        end_col = col,
    })
end

-- Set the cursor position in the current buffer. If head and anchor are different,
-- a visual selection is created. head and anchor are in UTF-16 code units.
local function setCursor(head, anchor)
    if head == anchor then
        anchor = head + 1
    end

    if head > anchor then
        head, anchor = anchor, head
    end

    -- If the cursor is at the end of the buffer, don't show it.
    -- This is because otherwise, the calculation that follows (to find the location for head+1 would fail.
    -- TODO: Find a way to display the cursor nevertheless.
    if head == utils.UTF16CodeUnits(utils.contentOfCurrentBuffer()) then
        return
    end

    local row, col = utils.UTF16CodeUnitOffsetToRowCol(head)
    local rowAnchor, colAnchor = utils.UTF16CodeUnitOffsetToRowCol(anchor)

    vim.api.nvim_buf_set_extmark(0, ns_id, row, col, {
        id = virtual_cursor,
        hl_mode = "combine",
        hl_group = "TermCursor",
        end_col = colAnchor,
        end_row = rowAnchor,
    })
end

-- Initialization function.
function Ethersync()
    if vim.fn.isdirectory(vim.fn.expand("%:p:h") .. "/.ethersync") ~= 1 then
        return
    end

    print("Ethersync activated!")

    local cmd = vim.lsp.rpc.connect("127.0.0.1", 9000)
    --local client_id = vim.lsp.start({ name = "ethersync", cmd = cmd })
    client = cmd({
        server_request = function(method, params)
            print("Server request: " .. method .. " " .. vim.inspect(params))

            if method == "insert" then
                local filename = params[1]
                local theEditorRevision = tonumber(params[2])
                local index = tonumber(params[3])
                local content = params[4]
                if
                    theEditorRevision == editorRevision
                    and filename == vim.fs.basename(vim.api.nvim_buf_get_name(0))
                then
                    insert(index, content)
                end
            elseif method == "delete" then
                local filename = params[1]
                local theEditorRevision = tonumber(params[2])
                local index = tonumber(params[3])
                local length = tonumber(params[4])
                if
                    theEditorRevision == editorRevision
                    and filename == vim.fs.basename(vim.api.nvim_buf_get_name(0))
                then
                    delete(index, length)
                end
            elseif method == "cursor" then
                --local filename = params[1]
                local head = tonumber(params[2])
                local anchor = tonumber(params[3])
                -- TODO: check filename, as soon as daemon sends filename correctly
                -- if filename == vim.fs.basename(vim.api.nvim_buf_get_name(0)) then
                setCursor(head, anchor)
                --end
            end
            return { "ok" }
        end,
    })

    createCursor()

    vim.api.nvim_buf_attach(0, false, {
        on_bytes = function(
            _the_string_bytes,
            _buffer_handle,
            changedtick,
            _start_row,
            _start_column,
            byte_offset,
            _old_end_row,
            _old_end_column,
            old_end_byte_length,
            _new_end_row,
            _new_end_column,
            new_end_byte_length
        )
            local content = utils.contentOfCurrentBuffer()

            -- Did the change come from us? If so, ignore it.
            if ignored_ticks[changedtick] then
                ignored_ticks[changedtick] = nil
                previousContent = content
                return
            end

            local filename = vim.fs.basename(vim.api.nvim_buf_get_name(0))

            if byte_offset + new_end_byte_length > vim.fn.strlen(content) then
                -- Tried to insert something *after* the end of the (resulting) file.
                -- I think this is probably a bug, that happens when you use the 'o' command, for example.
                byte_offset = vim.fn.strlen(content) - new_end_byte_length
            end

            local charOffsetUTF16CodeUnits = utils.byteOffsetToUTF16CodeUnitOffset(byte_offset)
            local oldEndCharUTF16CodeUnits =
                utils.byteOffsetToUTF16CodeUnitOffset(byte_offset + old_end_byte_length, previousContent)
            local newEndCharUTF16CodeUnits = utils.byteOffsetToUTF16CodeUnitOffset(byte_offset + new_end_byte_length)

            local oldEndCharUTF16CodeUnitsLength = oldEndCharUTF16CodeUnits - charOffsetUTF16CodeUnits
            local newEndCharUTF16CodeUnitsLength = newEndCharUTF16CodeUnits - charOffsetUTF16CodeUnits

            if oldEndCharUTF16CodeUnitsLength > 0 then
                RequestSync(
                    "delete",
                    { filename, daemonRevision, charOffsetUTF16CodeUnits, oldEndCharUTF16CodeUnitsLength }
                )
            end

            if newEndCharUTF16CodeUnitsLength > 0 then
                local insertedString = vim.fn.strpart(content, byte_offset, new_end_byte_length)
                RequestSync("insert", { filename, daemonRevision, charOffsetUTF16CodeUnits, insertedString })
            end

            previousContent = content
        end,
    })

    vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
        callback = function()
            local row, col = unpack(vim.api.nvim_win_get_cursor(0))
            local head = utils.rowColToIndex(row, col)
            local headUTF16CodeUnits = utils.charOffsetToUTF16CodeUnitOffset(head)

            if headUTF16CodeUnits == -1 then
                -- TODO what happens here?
                return
            end

            -- Is there a visual selection?
            local visualSelection = vim.fn.mode() == "v" or vim.fn.mode() == "V" or vim.fn.mode() == ""

            local anchorUTF16CodeUnits = headUTF16CodeUnits
            if visualSelection then
                -- Note: colV is the *byte* position, starting at *1*!
                local _, rowV, colV = unpack(vim.fn.getpos("v"))
                local anchor = utils.rowColToIndex(rowV, colV - 1)
                if head >= anchor then
                    head = head + 1
                else
                    anchor = anchor + 1
                end
                headUTF16CodeUnits = utils.charOffsetToUTF16CodeUnitOffset(head)
                anchorUTF16CodeUnits = utils.charOffsetToUTF16CodeUnitOffset(anchor)
            end
            local filename = vim.fs.basename(vim.api.nvim_buf_get_name(0))
            RequestSync("cursor", { filename, headUTF16CodeUnits, anchorUTF16CodeUnits })
        end,
    })
end

-- Stolen from Neovim source code.
function RequestSync(method, params, timeout_ms, bufnr)
    local request_result = nil
    local function _sync_handler(err, result)
        request_result = { err = err, result = result }
    end

    local success, request_id = client.request(method, params, _sync_handler, bufnr)
    if not success then
        return nil
    end

    local wait_result, reason = vim.wait(timeout_ms or 1000, function()
        return request_result ~= nil
    end, 10)

    if not wait_result then
        if request_id then
            client.cancel_request(request_id)
        end
        local wait_result_reason = { [-1] = "timeout", [-2] = "interrupted", [-3] = "error" }
        return nil, wait_result_reason[reason]
    end
    return request_result
end

-- When new buffer is loaded, run Ethersync.
vim.api.nvim_exec(
    [[
augroup Ethersync
    autocmd!
    autocmd BufEnter * lua Ethersync()
augroup END
]],
    false
)

-- Here are two other ways to run Ethersync:
vim.api.nvim_create_user_command("Ethersync", Ethersync, {})
vim.api.nvim_create_user_command("EthersyncRunTests", utils.testAllUnits, {})
vim.keymap.set("n", "<Leader>p", Ethersync)