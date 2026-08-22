function love.conf(t)
  local id = os.getenv("BOTS_IDENTITY")
  t.identity           = (id ~= nil and id ~= "") and id or "bots_reforest"
  t.version            = "11.4"          -- matches the love.js runtime used for the web build
  t.console            = false
  t.appendidentity     = false

  t.window.title       = "BOTS: Save Us All - Reforest"
  -- The browser build runs at whatever aspect the window is, so every screen has
  -- to survive shapes other than 16:9. BOTS_W/BOTS_H let the capture harness
  -- test that; without them these were the only dimensions anything ever saw.
  t.window.width       = tonumber(os.getenv("BOTS_W") or "") or 1600
  t.window.height      = tonumber(os.getenv("BOTS_H") or "") or 900
  t.window.minwidth    = 854
  t.window.minheight   = 480
  t.window.resizable   = true
  -- Fullscreen is the default shape of this game natively. Three cases keep a
  -- plain window: the headless capture harness, anyone who names a size with
  -- BOTS_W/BOTS_H, and the browser -- where the canvas is already sized to the
  -- page by the shell, and asking SDL for fullscreen makes it size the canvas
  -- to the *screen* instead, which overflows the viewport. The page has its
  -- own fullscreen, and it is the browser's to give. F11 toggles either way.
  local web = false
  if type(_G.arg) == "table" then
    for i = 1, #_G.arg do
      if tostring(_G.arg[i]):match("^%-%-BOTS_WEB=") then web = true break end
    end
  end
  local sized    = (os.getenv("BOTS_W") or "") ~= "" or (os.getenv("BOTS_H") or "") ~= ""
  local headless = (os.getenv("BOTS_HEADLESS") or "") ~= ""
  t.window.fullscreen     = not (sized or headless or web)
  t.window.fullscreentype = "desktop"
  t.window.vsync       = 1
  t.window.msaa        = 0               -- we anti-alias in the post chain instead
  t.window.stencil     = true
  t.window.depth       = 0
  t.window.highdpi     = true

  t.modules.physics    = false
  t.modules.video      = false
  t.modules.thread     = false
end
