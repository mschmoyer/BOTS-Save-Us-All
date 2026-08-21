function love.conf(t)
  t.identity           = "bots_reforest"
  t.version            = "11.4"          -- matches the love.js runtime used for the web build
  t.console            = false
  t.appendidentity     = false

  t.window.title       = "BOTS: Save Us All - Reforest"
  t.window.width       = 1600
  t.window.height      = 900
  t.window.minwidth    = 854
  t.window.minheight   = 480
  t.window.resizable   = true
  t.window.vsync       = 1
  t.window.msaa        = 0               -- we anti-alias in the post chain instead
  t.window.stencil     = true
  t.window.depth       = 0
  t.window.highdpi     = true

  t.modules.physics    = false
  t.modules.video      = false
  t.modules.thread     = false
end
