-- dronage-norns swappable render layer
-- A widget renders the SAME at every call site -- `w:draw(x, y, value)`. WHAT it draws is
-- chosen once at construction: norns Text, a procedural Shape, or a blitted 16-level
-- grayscale Sprite frame. Make art with the norns-img toolchain, drop the PNG in images/,
-- and `w:set_renderer(ui.Sprite.new{...})` -- no call-site changes. Sprite falls back to
-- Text if the asset is missing, so a half-finished art set still runs.

local M = {}

-- TEXT -------------------------------------------------------------------------
local Text = {}; Text.__index = Text
function Text.new(o)
  o = o or {}
  return setmetatable({ face = o.face or 1, size = o.size or 8, level = o.level or 15,
                        fmt = o.fmt or tostring, align = o.align or "left" }, Text)
end
function Text:draw(x, y, value)
  screen.font_face(self.face); screen.font_size(self.size); screen.level(self.level)
  screen.move(x, y)
  local s = self.fmt(value)
  if self.align == "center" then screen.text_center(s)
  elseif self.align == "right" then screen.text_right(s)
  else screen.text(s) end
end

-- SHAPE (procedural; reactive without any art) ---------------------------------
local Shape = {}; Shape.__index = Shape
function Shape.new(o)
  o = o or {}
  return setmetatable({ kind = o.kind or "orb", min = o.min or 0, max = o.max or 1,
                        size = o.size or 6 }, Shape)
end
function Shape:draw(x, y, value)
  local n = util.clamp(util.linlin(self.min, self.max, 0, 1, value or 0), 0, 1)
  screen.level(util.round(2 + n * 13))
  if self.kind == "bar" then
    local h = util.round(self.size * n)
    screen.rect(x, y - h, 3, h + 1); screen.fill()
  else -- orb
    screen.circle(x, y, 1 + n * self.size); screen.fill()
  end
end

-- SPRITE (16-level grayscale sheet; frame chosen from value) -------------------
local Sprite = {}; Sprite.__index = Sprite
function Sprite.new(o)
  local ok, img = pcall(screen.load_png, o.path)
  if not ok or not img then
    return Text.new({ fmt = o.fallback_fmt or function(v) return string.format("%.2f", v or 0) end })
  end
  return setmetatable({ img = img, fw = o.fw, fh = o.fh, cols = o.cols or 1,
                        count = o.count or 1, min = o.min or 0, max = o.max or 1 }, Sprite)
end
function Sprite:draw(x, y, value)
  local f = util.clamp(util.round(util.linlin(self.min, self.max, 0, self.count - 1, value or 0)), 0, self.count - 1)
  local left = (f % self.cols) * self.fw
  local top  = math.floor(f / self.cols) * self.fh
  screen.display_image_region(self.img, left, top, self.fw, self.fh, x, y)
end

-- WIDGET -----------------------------------------------------------------------
local Widget = {}; Widget.__index = Widget
function Widget.new(renderer) return setmetatable({ r = renderer }, Widget) end
function Widget:draw(x, y, value) self.r:draw(x, y, value) end
function Widget:set_renderer(r) self.r = r end

M.Text, M.Shape, M.Sprite, M.Widget = Text, Shape, Sprite, Widget
return M
