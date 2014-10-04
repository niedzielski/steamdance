{parseXY} = Simulator

compiler = require('boilerplate-compiler')

compile = (grid) ->
  buffer = []
  # I could use a real stream here, but then my test would be asyncronous.
  stream =
    write: (str) -> buffer.push str
    end: ->

  start = Date.now()
  ast = compiler.compileGrid grid, {stream, module:'bare', debug:no, fillMode:'engines'}

  code = buffer.join ''

  #console.log 'code length', code.length
  #console.log code
  f = new Function(code)
  {states, calcPressure, updateShuttles, getPressure} = f()

  end = Date.now()
  console.log "Compiled to #{code.length} bytes of js in #{end - start} ms"

  {states, calcPressure, updateShuttles, getPressure, ast, grid}

lerp = (t, x, y) -> t * y + (1 - t) * x

class Boilerplate
  fill = (initial_square, f) ->
    visited = {}
    visited["#{initial_square.x},#{initial_square.y}"] = true
    to_explore = [initial_square]
    hmm = (x,y) ->
      k = "#{x},#{y}"
      if not visited[k]
        visited[k] = true
        to_explore.push {x,y}
    while n = to_explore.shift()
      ok = f n.x, n.y, hmm
      if ok
        hmm n.x+1, n.y
        hmm n.x-1, n.y
        hmm n.x, n.y+1
        hmm n.x, n.y-1
    return

  @colors =
    bridge: 'hsl(203, 67%, 51%)'
    negative: 'hsl(16, 68%, 50%)'
    nothing: 'hsl(0, 0%, 100%)'
    positive: 'hsl(120, 52%, 58%)'
    shuttle: 'hsl(283, 65%, 45%)'
    solid: 'hsl(184, 49%, 7%)'
    thinshuttle: 'hsl(283, 89%, 75%)'
    thinsolid: 'hsl(0, 0%, 71%)'
    buttondown: 'rgb(255,169,61)'
    buttonup: 'rgb(204,123,0)'

  @darkColors =
    bridge: "hsl(203,34%,43%)"
    negative: "hsl(16,40%,36%)"
    nothing: 'hsl(0, 0%, 100%)'
    positive: "hsl(120,30%,43%)"
    shuttle: "hsl(287,24%,33%)"
    solid: "hsl(249,3%,45%)"
    thinshuttle: "hsl(283,31%,49%)"
    thinsolid: "hsl(0, 0%, 49%)"
    buttondown: 'rgb(255,169,61)'
    buttonup: 'rgb(171,99,18)'
  
  line = (x0, y0, x1, y1, f) ->
    dx = Math.abs x1-x0
    dy = Math.abs y1-y0
    ix = if x0 < x1 then 1 else -1
    iy = if y0 < y1 then 1 else -1
    e = 0
    for i in [0..dx+dy]
      f x0, y0
      e1 = e + dy
      e2 = e - dx
      if Math.abs(e1) < Math.abs(e2)
        x0 += ix
        e = e1
      else
        y0 += iy
        e = e2
    return

  enclosingRect = (a, b) ->
    tx: Math.min a.tx, b.tx
    ty: Math.min a.ty, b.ty
    tw: Math.abs(b.tx-a.tx) + 1
    th: Math.abs(b.ty-a.ty) + 1

  clamp = (x, min, max) -> Math.max(Math.min(x, max), min)

  changeTool: (newTool) ->
    @activeTool = if newTool is 'solid' then null else newTool
    @onToolChanged? @activeTool
    @updateCursor()

  addKeyListener: (el) ->
    el.addEventListener 'keydown', (e) =>
      kc = e.keyCode

      newTool = ({
        # 1-9
        49: 'nothing'
        50: 'thinsolid'
        51: 'solid'
        52: 'positive'
        53: 'negative'
        54: 'shuttle'
        55: 'thinshuttle'
        56: 'bridge'
        57: 'buttonup'

        80: 'positive' # p
        78: 'negative' # n
        83: 'shuttle' # s
        65: 'thinshuttle' # a
        69: 'nothing' # e
        71: 'thinsolid' # g
        68: 'solid' # d
        66: 'bridge' # b
        84: 'buttonup' # t
      })[kc]
      if newTool
        @selection = @selectOffset = null
        @changeTool newTool

      switch kc
        when 37 # left
          @scroll_x -= 1 if @canScroll
        when 39 # right
          @scroll_x += 1 if @canScroll
        when 38 # up
          @scroll_y -= 1 if @canScroll
        when 40 # down
          @scroll_y += 1 if @canScroll

        when 16 # shift
          @imminent_select = true
        when 27,192 # esc
          if @selection
            @selection = @selectOffset = null
          else
            @changeTool 'move'

        when 88 # x
          @flip 'x' if @selection
        when 89 # y
          @flip 'y' if @selection
        when 77 # m
          @mirror() if @selection

      @draw()

    el.addEventListener 'keyup', (e) =>
      if e.keyCode == 16 # shift
        @imminent_select = false
        @draw()

    el.addEventListener 'blur', =>
      @releaseButton()
      @mouse.mode = null
      @imminent_select = false
      @draw()

    el.addEventListener 'copy', (e) => @copy(e)
    el.addEventListener 'paste', (e) => @paste(e)


  
  # ----- Utility methods for panning around the screen

  # given pixel x,y returns tile x,y
  screenToWorld: (px, py) ->
    return {tx:null, ty:null} unless px?
    # first, the top-left pixel of the screen is at |_ scroll * size _| px from origin
    px += Math.floor(@scroll_x * @size)
    py += Math.floor(@scroll_y * @size)
    # now we can simply divide and floor to find the tile
    tx = Math.floor(px / @size)
    ty = Math.floor(py / @size)
    {tx,ty}

  # given tile x,y returns the pixel x,y,w,h at which the tile resides on the screen.
  worldToScreen: (tx, ty) ->
    return {px:null, py:null} unless tx?
    px: tx * @size - Math.floor(@scroll_x * @size)
    py: ty * @size - Math.floor(@scroll_y * @size)

  zoomBy: (diff) ->
    @zoomLevel += diff
    @zoomLevel = clamp @zoomLevel, 1/20, 5
    @size = Math.floor 20 * @zoomLevel

  ###
  get: (tx, ty) ->
    k = "#{tx},#{ty}"
    sid = @compiled.ast.shuttleGrid[k]
    if sid?
      state = @compiled.states[sid]
      shuttle = @compiled.ast.shuttles[sid]
      {dx,dy} = shuttle.states[state]
      return shuttle.points["#{tx-dx},#{ty-dy}"] || 'nothing'
    else
      @compiled.grid[k]
  ###

  getGrid: -> @compiled.grid

  constructor: (@el, options) ->
    @zoomLevel = 1
    @zoomBy 0

    @activeTool = 'move'

    @grid = options.grid
    @compile()

    # In tile coordinates
    @scroll_x = options.initialX || 0
    @scroll_y = options.initialY || 0

    @canScroll = options.canScroll ? true

    @animTime = options.animTime || 0

    #@el = document.createElement 'div'
    #@el.className = 'boilerplate'
    @el.tabIndex = 0 if @el.tabIndex is -1 # allow keyboard events
    @canvas = @el.appendChild document.createElement 'canvas'
    @canvas.className = 'draw'

    @el.boilerplate = this

    @resizeTo el.offsetWidth, el.offsetHeight
    #@el.onresize = -> console.log 'yo'

    @mouse = {x:null,y:null, mode:null}
    #@placing = 'nothing'
    @imminent_select = false
    @selectedA = @selectedB = null
    @selectOffset = null
    @selection = null

    @draw()


    # ----- Event handlers

    @el.onmousemove = (e) =>
      @imminent_select = !!e.shiftKey
      # If the mouse is released / pressed while not in the box, handle that correctly

      @el.onmousedown e if e.button && !@mouse.mode

      @mouse.from = {tx: @mouse.tx, ty: @mouse.ty}
      @mouse.x = clamp e.offsetX, 0, @el.offsetWidth - 1
      @mouse.y = clamp e.offsetY, 0, @el.offsetHeight - 1
      {tx, ty} = @screenToWorld @mouse.x, @mouse.y

      if tx != @mouse.tx || ty != @mouse.ty
        @mouse.tx = tx; @mouse.ty = ty

        switch @mouse.mode
          when 'paint' then @paint()
          when 'select' then @selectedB = @screenToWorld @mouse.x, @mouse.y

        @dragShuttleTo tx, ty

        @updateCursor()
        @draw()

    @el.onmousedown = (e) =>
      if e.shiftKey
        @mouse.mode = 'select'
        @selection = @selectOffset = null
        @selectedA = @screenToWorld @mouse.x, @mouse.y
        @selectedB = @selectedA
      else if @selection
        @stamp()
      else
        if @activeTool is 'move'
          v = @compiled.grid["#{@mouse.tx},#{@mouse.ty}"]
          if v is 'buttonup'
            @pressButton @mouse.tx, @mouse.ty
          else if v in ['shuttle', 'thinshuttle']
            # find the shuttle id for the shuttle under the cursor
            @compile() if @needsCompile
            sid = @compiled.ast.shuttleGrid[[@mouse.tx, @mouse.ty]]
            shuttle = @compiled.ast.shuttles[sid]
            if !shuttle.immobile
              {dx,dy} = shuttle.states[@compiled.states[sid]]
              @draggedShuttle =
                sid: sid
                heldPoint: {x:@mouse.tx - dx, y:@mouse.ty - dy}

            #@simulator.holdShuttle @draggedShuttle
        else
          @mouse.mode = 'paint'
          @mouse.from = {tx:@mouse.tx, ty:@mouse.ty}
          @paint()
      @updateCursor()
      @draw()

    @el.onmouseup = =>
      @releaseButton()
      @draggedShuttle = null
      
      #@compile() if @needsCompile

      if @mouse.mode is 'select'
        @selection = @copySubgrid enclosingRect @selectedA, @selectedB
        @selectOffset =
          tx:@selectedB.tx - Math.min @selectedA.tx, @selectedB.tx
          ty:@selectedB.ty - Math.min @selectedA.ty, @selectedB.ty

      @mouse.mode = null
      @imminent_select = false
      @updateCursor()
      @draw()
      @onEditFinish?()

    @el.onmouseout = (e) =>
      # Pretend the mouse just went up at the edge of the boilerplate instance then went away.
      @el.onmousemove e
      @mouse.x = @mouse.y = @mouse.from = @mouse.tx = @mouse.ty = null
      # ... But if we're drawing, stay in drawing mode.
      @mouse.mode = null# if @mouse.mode is 'select'
      @releaseButton()
      @draw()

    @el.onmouseenter = (e) =>
      if e.which
        @el.onmousemove e
        @el.onmousedown e

    @el.onmousewheel = (e) =>
      return unless @canScroll
      if e.shiftKey
        oldsize = @size
        @zoomBy e.wheelDeltaY / 800

        @scroll_x += @mouse.x / oldsize - @mouse.x / @size
        @scroll_y += @mouse.y / oldsize - @mouse.y / @size
      else
        @scroll_x += e.wheelDeltaX / (-2 * @size)
        @scroll_y += e.wheelDeltaY / (-2 * @size)
      {tx:@mouse.tx, ty:@mouse.ty} = @screenToWorld @mouse.x, @mouse.y
      e.preventDefault()
      @updateCursor()
      @draw()

  updateCursor: ->
    @canvas.style.cursor =
      if @activeTool is 'move' and !@imminent_select
        if @draggedShuttle?
          '-webkit-grabbing'
        else if @compiled.grid["#{@mouse.tx},#{@mouse.ty}"] in ['shuttle', 'thinshuttle']
          '-webkit-grab'
        else if @compiled.grid["#{@mouse.tx},#{@mouse.ty}"] in ['buttonup', 'buttondown']
          'pointer'
        else
          'default'
      else
        'crosshair'

  resizeTo: (width, height) ->
    @canvas.width = width * devicePixelRatio
    @canvas.height = height * devicePixelRatio
    @canvas.style.width = width + 'px'
    @canvas.style.height = height + 'px'
    @ctx = @canvas.getContext '2d'
    @ctx.scale devicePixelRatio, devicePixelRatio

    @draw()

  paint: ->
    throw 'Invalid placing' if @activeTool is 'move'
    {tx, ty} = @mouse
    {tx:fromtx, ty:fromty} = @mouse.from
    fromtx ?= tx
    fromty ?= ty

    line fromtx, fromty, tx, ty, (x, y) =>
      #@simulator.set x, y, @activeTool
      if @activeTool?
        @compiled.grid[[x,y]] = @activeTool
      else
        delete @compiled.grid[[x,y]]
      @onEdit? x, y, @activeTool
    @gridChanged()

  compile: ->
    @needsCompile = no
    @compiled = compile @grid
    @compiled.calcPressure()
    @prevStates = new @compiled.states.constructor @compiled.states
    @states = @compiled.states
    @draw()

  gridChanged: ->
    @needsCompile = true
    @draw()

  step: ->
    @compile() if @needsCompile
    #return if @needsCompile

    for v, sid in @states
      @prevStates[sid] = @states[sid]

    @compiled.updateShuttles()

    if @draggedShuttle?
      @states[@draggedShuttle.sid] = @prevStates[@draggedShuttle.sid]

    for v, sid in @states
      @moveShuttle sid, @prevStates[sid], v

    @lastStepAt = Date.now()

    @compiled.calcPressure()
    @draw()
    @updateCursor()

  moveShuttle: (sid, from, to) ->
    compiler.util.moveShuttle @compiled.grid, @compiled.ast.shuttles, sid, from, to

  #########################
  # BUTTONS               #
  #########################
  pressButton: (tx, ty) ->
    @pressedButton = []
    ###
    if @simulator.get(tx, ty) == 'buttonup'
      fill {x:tx, y:ty}, (x, y) =>
        if @simulator.get(x, y) == 'buttonup'
          @simulator.set x, y, 'buttondown'
          @pressedButton.push {x, y}
          true
        else
          false
    ###
  releaseButton: ->
    return unless @pressedButton
    for {x, y} in @pressedButton
      @simulator.set x, y, 'buttonup' if @simulator.get(x,y) == 'buttondown'
    @pressedButton = null

  dragShuttleTo: (tx, ty) ->
    return unless @draggedShuttle?

    return if @needsCompile

    {sid, heldPoint} = @draggedShuttle
    shuttle = @compiled.ast.shuttles[sid]

    dist2 = ({x:x1,y:y1},{x:x2,y:y2}) -> dx = x2-x1; dy = y2-y1; dx*dx+dy*dy
    minDist = null
    bestState = @compiled.states[sid]
    for {dx, dy},state in shuttle.states
      if (d = dist2({x:heldPoint.x + dx, y:heldPoint.y + dy}, {x:tx, y:ty})) < minDist or !minDist?
        bestState = state
        minDist = d

    if @states[sid] != bestState
      @moveShuttle sid, @states[sid], bestState
      @states[sid] = @prevStates[sid] = bestState
      @compiled.calcPressure()
      @draw()

  #########################
  # SELECTION             #
  #########################
  copySubgrid: (rect) ->
    {tx, ty, tw, th} = rect
    subgrid = {tw,th}
    for y in [ty..ty+th]
      for x in [tx..tx+tw]
        if s = @compiled.grid[[x,y]]
          subgrid[[x-tx,y-ty]] = s
    subgrid

  flip: (dir) ->
    return unless @selection
    new_selection = {tw:tw = @selection.tw, th:th = @selection.th}
    for k,v of @selection
      {x:tx,y:ty} = parseXY k
      tx_ = if 'x' in dir then tw-1 - tx else tx
      ty_ = if 'y' in dir then th-1 - ty else ty
      new_selection[[tx_,ty_]] = v
    @selection = new_selection

  mirror: ->
    return unless @selection
    new_selection = {tw:tw = @selection.th, th:th = @selection.tw}
    for k,v of @selection
      {x:tx,y:ty} = parseXY k
      new_selection[[ty,tx]] = v
    @selection = new_selection

  stamp: ->
    throw new Error 'tried to stamp without a selection' unless @selection
    {tx:mtx, ty:mty} = @screenToWorld @mouse.x, @mouse.y
    mtx -= @selectOffset.tx
    mty -= @selectOffset.ty

    changed = no
    for y in [0...@selection.th]
      for x in [0...@selection.tw]
        tx = mtx+x
        ty = mty+y
        if (s = @selection[[x,y]]) != @compiled.grid[[tx,ty]]
          changed = yes
          if s?
            @compiled.grid[[tx,ty]] = s
          else
            delete @compiled.grid[[tx,ty]]
          @onEdit? tx, ty, s
    @gridChanged() if changed

  copy: (e) ->
    #console.log 'copy'
    if @selection
      e.clipboardData.setData 'text', JSON.stringify @selection

      console.log JSON.stringify @selection
    e.preventDefault()

  paste: (e) ->
    console.log 'paste'
    data = e.clipboardData.getData 'text'
    if data
      try
        @selection = JSON.parse data
        tw = th = 0
        for k, v of @selection
          {x,y} = parseXY k
          tw = x+1 if x >= tw
          th = y+1 if y >= th
        @selection.tw = tw; @selection.th = th
        @selectOffset = {tx:0, ty:0}


  #########################
  # DRAWING               #
  #########################

  draw: ->
    return if @needsDraw
    @needsDraw = true
    requestAnimationFrame =>
      @needsDraw = false
      @drawFrame()

  drawFrame: ->
    @ctx.fillStyle = Boilerplate.colors['solid']
    @ctx.fillRect 0, 0, @canvas.width, @canvas.height

    @drawGrid()

    @drawEditControls()

  drawGrid: ->
    t = if @animTime && @lastStepAt
      now = Date.now()
      exact = Math.min 1, (now - @lastStepAt) / @animTime

      ((exact * @size)|0) / @size
    else
      1

    shuttleOverlay = []

    # Draw the tiles
    #pressure = @simulator.getPressure()
    for k,v of @compiled.grid
      {x:tx,y:ty} = parseXY k
      {px, py} = @worldToScreen tx, ty
      if px+@size >= 0 and px < @canvas.width and py+@size >= 0 and py < @canvas.height
        if !@needsCompile and t <= 1 and v in ['shuttle', 'thinshuttle']
          sid = @compiled.ast.shuttleGrid[k]
          if !@compiled.ast.shuttles[sid].immobile
            shuttleOverlay.push {k, tx, ty, v}
            v = 'nothing'

        @ctx.fillStyle = Boilerplate.colors[v]
        @ctx.fillRect px, py, @size, @size

        ###
        downCells = ['nothing', 'buttondown']
        v2 = @compiled.grid["#{tx},#{ty-1}"]
        if v in downCells and v != v2
          @ctx.fillStyle = Boilerplate.darkColors[v2 ? 'solid']
          @ctx.fillRect px, py, @size, @size*0.3
        ###

        rid = @compiled.ast.regionGrid[k]
        unless rid?
          # We might be able to find the region if its in a shuttle zone based
          # on the state of the shuttle.
          if (sid = @compiled.ast.shuttleGrid[k])?
            shuttle = @compiled.ast.shuttles[sid]
            rid = shuttle.adjacentTo[k]?[@states[sid]] ||
              shuttle.adjacentTo[k]?[@prevStates[sid]]

        if rid?
          p = @compiled.getPressure(rid)
          if p != 0
            @ctx.fillStyle = if p < 0 then 'rgba(255,0,0,0.2)' else 'rgba(0,255,0,0.15)'
            @ctx.fillRect px, py, @size, @size

    for {k, tx, ty, v} in shuttleOverlay
      sid = @compiled.ast.shuttleGrid[k]
      shuttle = @compiled.ast.shuttles[sid]
      state = shuttle.states[@states[sid]]
      prevState = shuttle.states[@prevStates[sid]]

      prevtx = tx + prevState.dx - state.dx
      prevty = ty + prevState.dy - state.dy

      #@ctx.fillStyle = Boilerplate.colors.nothing
      #@ctx.fillRect px, py, @size, @size

      {px, py} = @worldToScreen lerp(t, prevtx, tx), lerp(t, prevty, ty)

      @ctx.fillStyle = Boilerplate.colors[v]
      @ctx.fillRect px, py, @size, @size



    zeroPos = @worldToScreen 0, 0
    @ctx.lineWidth = 3
    @ctx.strokeStyle = 'yellow'

    @draw() if t != 1

  drawEditControls: ->
    mx = @mouse.x
    my = @mouse.y
    {tx:mtx, ty:mty} = @screenToWorld mx, my
    {px:mpx, py:mpy} = @worldToScreen mtx, mty

    if @mouse.mode is 'select'
      sa = @selectedA
      sb = @selectedB
    else if @imminent_select
      sa = sb = {tx:mtx, ty:mty}

    @ctx.lineWidth = 1

    # Draw the mouse hover state
    if @mouse.tx != null
      if sa
        {tx, ty, tw, th} = enclosingRect sa, sb
        {px, py} = @worldToScreen tx, ty
        @ctx.fillStyle = 'rgba(0,0,255,0.5)'
        @ctx.fillRect px, py, tw*@size, th*@size

        @ctx.strokeStyle = 'rgba(0,255,255,0.5)'
        @ctx.strokeRect px, py, tw*@size, th*@size
      else if @selection # mouse.tx is null when the mouse isn't in the div
        @ctx.globalAlpha = 0.8
        for y in [0...@selection.th]
          for x in [0...@selection.tw]
            {px, py} = @worldToScreen x+mtx-@selectOffset.tx, y+mty-@selectOffset.ty
            if px+@size >= 0 and px < @canvas.width and py+@size >= 0 and py < @canvas.height
              v = @selection[[x,y]]
              @ctx.fillStyle = if v then Boilerplate.colors[v] else Boilerplate.colors['solid']
              @ctx.fillRect px, py, @size, @size
        @ctx.strokeStyle = 'rgba(0,255,255,0.5)'
        @ctx.strokeRect mpx - @selectOffset.tx*@size, mpy - @selectOffset.ty*@size, @selection.tw*@size, @selection.th*@size
        @ctx.globalAlpha = 1
      else if mpx? and @activeTool != 'move'
        # Mouse hover
        @ctx.fillStyle = Boilerplate.colors[@activeTool ? 'solid']
        @ctx.fillRect mpx + @size/4, mpy + @size/4, @size/2, @size/2

        @ctx.strokeStyle = if @compiled.grid["#{mtx},#{mty}"] then 'black' else 'white'
        @ctx.strokeRect mpx + 1, mpy + 1, @size - 2, @size - 2


    return

