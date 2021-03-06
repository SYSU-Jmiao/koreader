local InputContainer = require("ui/widget/container/inputcontainer")
local Blitbuffer = require("ffi/blitbuffer")
local Widget = require("ui/widget/widget")
local GestureRange = require("ui/gesturerange")
local RenderText = require("ui/rendertext")
local UIManager = require("ui/uimanager")
local Device = require("device")
local Screen = require("device").screen
local Geom = require("ui/geometry")
local util = require("util")
local DEBUG = require("dbg")

--[[
A TextWidget that handles long text wrapping
--]]
local TextBoxWidget = Widget:new{
    text = nil,
    face = nil,
    bold = nil,
    fgcolor = Blitbuffer.COLOR_BLACK,
    width = 400, -- in pixels
    height = nil,
    first_line = 1,
    virtual_line = 1, -- used by scroll bar
    line_height = 0.3, -- in em
    v_list = nil,
    _bb = nil,
    _length = 0,
}

function TextBoxWidget:init()
    local v_list = nil
    if self.height then
        v_list = self:_getCurrentVerticalList()
    else
        v_list = self:_getVerticalList()
    end
    self:_render(v_list)
    self.dimen = Geom:new(self:getSize())
end

function TextBoxWidget:_wrapGreedyAlg(h_list)
    local line_height = (1 + self.line_height) * self.face.size
    local cur_line_width = 0
    local cur_line = {}
    local v_list = {}

    for k,w in ipairs(h_list) do
        w.box = {
            x = cur_line_width,
            w = w.width,
            h = line_height,
        }
        cur_line_width = cur_line_width + w.width
        if w.word == "\n" then
            if cur_line_width > 0 then
                -- hard line break
                table.insert(v_list, cur_line)
                cur_line = {}
                cur_line_width = 0
            end
        elseif cur_line_width > self.width then
            -- wrap to next line
            table.insert(v_list, cur_line)
            cur_line = {}
            cur_line_width = w.width
            table.insert(cur_line, w)
        else
            table.insert(cur_line, w)
        end
    end
    -- handle last line
    table.insert(v_list, cur_line)

    return v_list
end

function TextBoxWidget:_getVerticalList(alg)
    if self.vertical_list then
        return self.vertical_list
    end
    -- build horizontal list
    local h_list = {}
    local line_count = 0
    for line in util.gsplit(self.text, "\n", true) do
        for words in line:gmatch("[\32-\127\192-\255]+[\128-\191]*") do
            for word in util.gsplit(words, "%s+", true) do
                for w in util.gsplit(word, "%p+", true) do
                    local word_box = {}
                    word_box.word = w
                    word_box.width = RenderText:sizeUtf8Text(0, Screen:getWidth(), self.face, w, true, self.bold).x
                    table.insert(h_list, word_box)
                end
            end
        end
        if line:sub(-1) == "\n" then table.insert(h_list, {word = '\n', width = 0}) end
    end

    -- @TODO check alg here 25.04 2012 (houqp)
    -- @TODO replace greedy algorithm with K&P algorithm  25.04 2012 (houqp)
    self.vertical_list = self:_wrapGreedyAlg(h_list)
    return self.vertical_list
end

function TextBoxWidget:_getCurrentVerticalList()
    local line_height = (1 + self.line_height) * self.face.size
    local v_list = self:_getVerticalList()
    local current_v_list = {}
    local height = 0
    for i = self.first_line, #v_list do
        if height < self.height - line_height then
            table.insert(current_v_list, v_list[i])
            height = height + line_height
        else
            break
        end
    end
    return current_v_list
end

function TextBoxWidget:_getPreviousVerticalList()
    local line_height = (1 + self.line_height) * self.face.size
    local v_list = self:_getVerticalList()
    local previous_v_list = {}
    local height = 0
    if self.first_line == 1 then
        return self:_getCurrentVerticalList()
    end
    self.virtual_line = self.first_line
    for i = self.first_line - 1, 1, -1 do
        if height < self.height - line_height then
            table.insert(previous_v_list, 1, v_list[i])
            height = height + line_height
            self.virtual_line = self.virtual_line - 1
        else
            break
        end
    end
    for i = self.first_line, #v_list do
        if height < self.height - line_height then
            table.insert(previous_v_list, v_list[i])
            height = height + line_height
        else
            break
        end
    end
    if self.first_line > #previous_v_list then
        self.first_line = self.first_line - #previous_v_list
    else
        self.first_line = 1
    end
    return previous_v_list
end

function TextBoxWidget:_getNextVerticalList()
    local line_height = (1 + self.line_height) * self.face.size
    local v_list = self:_getVerticalList()
    local current_v_list = self:_getCurrentVerticalList()
    local next_v_list = {}
    local height = 0
    if self.first_line + #current_v_list > #v_list then
        return current_v_list
    end
    self.virtual_line = self.first_line
    for i = self.first_line + #current_v_list, #v_list do
        if height < self.height - line_height then
            table.insert(next_v_list, v_list[i])
            height = height + line_height
            self.virtual_line = self.virtual_line + 1
        else
            break
        end
    end
    self.first_line = self.first_line + #current_v_list
    return next_v_list
end

function TextBoxWidget:_render(v_list)
    self.rendering_vlist = v_list
    local font_height = self.face.size
    local line_height_px = self.line_height * font_height
    local space_w = RenderText:sizeUtf8Text(0, Screen:getWidth(), self.face, " ", true).x
    local h = (font_height + line_height_px) * #v_list
    self._bb = Blitbuffer.new(self.width, h)
    self._bb:fill(Blitbuffer.COLOR_WHITE)
    local y = font_height
    local pen_x = 0
    for _,l in ipairs(v_list) do
        pen_x = 0
        for _,w in ipairs(l) do
            w.box.y = y - line_height_px - font_height
            --@TODO Don't use kerning for monospaced fonts.    (houqp)
            -- refert to cb25029dddc42693cc7aaefbe47e9bd3b7e1a750 in master tree
            RenderText:renderUtf8Text(self._bb, pen_x, y, self.face, w.word, true, self.bold, self.fgcolor)
            pen_x = pen_x + w.width
        end
        y = y + line_height_px + font_height
    end
--    -- if text is shorter than one line, shrink to text's width
--    if #v_list == 1 then
--        self.width = pen_x
--    end
end

function TextBoxWidget:getVirtualLineNum()
    return self.virtual_line
end

function TextBoxWidget:getAllLineCount()
    local v_list = self:_getVerticalList()
    return #v_list
end

function TextBoxWidget:getVisLineCount()
    local line_height = (1 + self.line_height) * self.face.size
    return math.floor(self.height / line_height)
end

function TextBoxWidget:scrollDown()
    local next_v_list = self:_getNextVerticalList()
    self:free()
    self:_render(next_v_list)
end

function TextBoxWidget:scrollUp()
    local previous_v_list = self:_getPreviousVerticalList()
    self:free()
    self:_render(previous_v_list)
end

function TextBoxWidget:getSize()
    if self.width and self.height then
        return Geom:new{ w = self.width, h = self.height}
    else
        return Geom:new{ w = self.width, h = self._bb:getHeight()}
    end
end

function TextBoxWidget:paintTo(bb, x, y)
    self.dimen.x, self.dimen.y = x, y
    bb:blitFrom(self._bb, x, y, 0, 0, self.width, self._bb:getHeight())
end

function TextBoxWidget:free()
    if self._bb then
        self._bb:free()
        self._bb = nil
    end
end

function TextBoxWidget:onHoldWord(callback, ges)
    local x, y = ges.pos.x - self.dimen.x, ges.pos.y - self.dimen.y
    for _, l in ipairs(self.rendering_vlist) do
        for _, w in ipairs(l) do
            local box = w.box
            if x > box.x and x < box.x + box.w and
                y > box.y and y < box.y + box.h then
                DEBUG("found word", w, "at", x, y)
                if callback then
                    callback(w.word)
                end
                break
            end
        end
    end
    return true
end

return TextBoxWidget
