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

# t=0 -> x, t=1 -> y
lerp = (t, x, y) -> (1 - t)*x + t*y

class Rectacular
  vertSource = """
  attribute vec2 a_position;
  attribute vec4 a_color;
  varying lowp vec4 v_color;

  uniform vec2 u_resolution;

  void main() {
     // convert the rectangle from pixels to 0.0 to 1.0
     vec2 zeroToOne = a_position / u_resolution;

     // convert from 0->1 to 0->2
     vec2 zeroToTwo = zeroToOne * 2.0;

     // convert from 0->2 to -1->+1 (clipspace)
     vec2 clipSpace = zeroToTwo - 1.0;

     gl_Position = vec4(clipSpace * vec2(1,-1), 0, 1);
     v_color = a_color;
  }
  """

  fragSource = """
  varying lowp vec4 v_color;
  void main() {
    gl_FragColor = v_color;
  }
  """

  loadShader = (gl, shaderSource, shaderType, opt_errorCallback) ->
    shader = gl.createShader(shaderType)
    gl.shaderSource(shader, shaderSource)
    gl.compileShader(shader)
    compiled = gl.getShaderParameter(shader, gl.COMPILE_STATUS)
    if !compiled
      lastError = gl.getShaderInfoLog(shader)
      console.error("*** Error compiling shader '" + shader + "':" + lastError)
      gl.deleteShader(shader)
      return null
    shader

  loadProgram = (gl, shaders, opt_attribs, opt_locations) ->
    program = gl.createProgram()
    for s in shaders
      gl.attachShader(program, s)
    if opt_attribs
      for attrib, i in opt_attribs
        gl.bindAttribLocation(
          program,
          if opt_locations then opt_locations[i] else i,
          attrib
        )
    gl.linkProgram(program)

    linked = gl.getProgramParameter(program, gl.LINK_STATUS)
    if !linked
      lastError = gl.getProgramInfoLog(program)
      console.error("Error in program linking:" + lastError)

      gl.deleteProgram(program)
      return null
    program


  cssColorToRGB = do ->
    s = document.createElement('span')
    s.id = '-color-converter'
    s.style.position = 'absolute'
    s.style.left = '-9999px'
    s.style.top = '-9999px'
    document.body.appendChild(s)
    cache = {}
    (cssColor) ->
      if cache[cssColor] then return cache[cssColor]
      s.style.backgroundColor = cssColor
      rgb = getComputedStyle(s).backgroundColor
      m = /^rgb\((\d+), (\d+), (\d+)\)$/.exec(rgb)
      if !m then m = /^rgba\((\d+), (\d+), (\d+), ([\d.]+)\)$/.exec(rgb)
      r = parseInt(m[1])
      g = parseInt(m[2])
      b = parseInt(m[3])
      a = if m[4] then parseFloat(m[4]) else 1.0
      cache[cssColor] = [r/255, g/255, b/255, a]

  constructor: (canvas) ->
    @gl = canvas.getContext 'experimental-webgl'
    vertexShader = loadShader(@gl, vertSource, @gl.VERTEX_SHADER)
    fragmentShader = loadShader(@gl, fragSource, @gl.FRAGMENT_SHADER)
    program = loadProgram(@gl, [vertexShader, fragmentShader])
    @gl.useProgram(program)

    @positionLocation = @gl.getAttribLocation(program, "a_position")
    @colorLocation = @gl.getAttribLocation(program, "a_color")
    resolutionLocation = @gl.getUniformLocation(program, "u_resolution")
    #console.log "setting resolution uniform to #{canvas.width}, #{canvas.height}"
    @gl.uniform2f(resolutionLocation, canvas.width, canvas.height)

    @vbuf = @gl.createBuffer()
    @gl.bindBuffer @gl.ARRAY_BUFFER, @vbuf
    @gl.bufferData @gl.ARRAY_BUFFER, 4*1000000*4, @gl.STATIC_DRAW
    @cbuf = @gl.createBuffer()
    @gl.bindBuffer @gl.ARRAY_BUFFER, @cbuf
    @gl.bufferData @gl.ARRAY_BUFFER, 4*1000000*6, @gl.STATIC_DRAW

    @gl.blendFunc @gl.SRC_ALPHA, @gl.ONE_MINUS_SRC_ALPHA
    @gl.enable @gl.BLEND

    @tris = []
    @colors = []
    @fillStyle = 'rgba(0,255,0,1.0)'
    @strokeStyle = 'rgba(0,255,0,1.0)'

  fillRect: (l, t, w, h) ->
    r = l+w
    b = t+h
    @tris.push.apply @tris, [
      l, t
      r, t
      l, b
      l, b
      r, t
      r, b
    ]
    [r, g, b, a] = cssColorToRGB @fillStyle
    @colors.push.apply @colors, [
      r, g, b, a
      r, g, b, a
      r, g, b, a
      r, g, b, a
      r, g, b, a
      r, g, b, a
    ]

  strokeRect: (l, t, w, h) ->
    oldFill = @fillStyle
    @fillStyle = @strokeStyle
    @fillRect l, t, w, 1
    @fillRect l, t+1, 1, h-1
    @fillRect l+w-1, t+1, 1, h-1
    @fillRect l+1, t+h-1, w-2, 1
    @fillStyle = oldFill

  flush: ->
    @gl.bindBuffer(@gl.ARRAY_BUFFER, @vbuf)
    # ugh
    max = 20000*6
    for i in [0..(@tris.length/max)|0]
      subData = new Float32Array @tris[i*max...((i+1)*max)]
      @gl.bufferSubData(@gl.ARRAY_BUFFER, i*max*4, subData)
    @gl.enableVertexAttribArray(@positionLocation)
    @gl.vertexAttribPointer(@positionLocation, 2, @gl.FLOAT, false, 0, 0)

    @gl.bindBuffer(@gl.ARRAY_BUFFER, @cbuf)
    for i in [0..(@colors.length/max)|0]
      subData = new Float32Array @colors[i*max...((i+1)*max)]
      @gl.bufferSubData(@gl.ARRAY_BUFFER, i*max*4, subData)
    @gl.enableVertexAttribArray(@colorLocation)
    @gl.vertexAttribPointer(@colorLocation, 4, @gl.FLOAT, false, 0, 0)

    @gl.drawArrays(@gl.TRIANGLES, 0, @tris.length/2)
    @tris = []
    @colors = []

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
    # Deprecated
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
    # Deprecated
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
        #57: 'buttonup'

        80: 'positive' # p
        78: 'negative' # n
        83: 'shuttle' # s
        65: 'thinshuttle' # a
        69: 'nothing' # e
        71: 'thinsolid' # g
        68: 'solid' # d
        66: 'bridge' # b
        #84: 'buttonup' # t
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
          if v in ['shuttle', 'thinshuttle']
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
        else
          'default'
      else
        'crosshair'

  resizeTo: (width, height) ->
    @canvas.width = width
    @canvas.height = height
    #@canvas.style.width = width + 'px'
    #@canvas.style.height = height + 'px'
    console.log "resized to #{width}x#{height}"
    
    @ctx = new Rectacular @canvas

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

    for s in @compiled.ast.shuttles
      s.edges = {}
      for k,v of s.points
        {x, y} = parseXY k
        e = 0
        # top
        e = e|1 if !s.points["#{x},#{y-1}"]
        # right
        e = e|2 if !s.points["#{x+1},#{y}"]
        # bot
        e = e|4 if !s.points["#{x},#{y+1}"]
        # left
        e = e|8 if !s.points["#{x-1},#{y}"]
        s.edges[k] = e

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

    @ctx.flush()


  drawShuttle: (t, sid) ->
    shuttle = @compiled.ast.shuttles[sid]

    if !shuttle.immobile
      stateid = @states[sid]
      state = shuttle.states[stateid]
      dx = state.dx; dy = state.dy

      if t < 1
        prevstateid = @prevStates[sid]
        prevstate = shuttle.states[prevstateid]

        moving = if dx != prevstate.dx
          dx = lerp t, prevstate.dx, dx
          'x'
        else if dy != prevstate.dy
          dy = lerp t, prevstate.dy, dy
          'y'

    else
      dx = dy = 0
      t = 1

    for k,v of shuttle.points
      {x,y} = parseXY k
      {px, py} = @worldToScreen x+dx, y+dy

      if px+@size >= 0 and px < @canvas.width and py+@size >= 0 and py < @canvas.height

        @ctx.fillStyle = Boilerplate.colors[v]
        #@ctx.fillStyle = Boilerplate.colors.shuttle
 
        px2 = px; py2 = py; sizex = sizey = @size

        e = shuttle.edges[k]
        if e
          b = if v is 'shuttle'
            @size * 0.04
          else
            #e = ~e
            @size * 0.3
          b = (b+1)|0
          # top, right, bottom, left
          if e & 1 then py2 += b; sizey -= b
          if e & 2 then sizex -= b
          if e & 4 then sizey -= b
          if e & 8 then px2 += b; sizex -= b
        @ctx.fillRect px2, py2, sizex, sizey

        # Fill back in inner corners
        @ctx.fillStyle = Boilerplate.colors.nothing
        if (e & 0x9) == 0 && !shuttle.points["#{x-1},#{y-1}"] # top left
          @ctx.fillRect px, py, b, b
        if (e & 0x3) == 0 && !shuttle.points["#{x+1},#{y-1}"] # top right
          @ctx.fillRect px + @size - b, py, b, b
        if (e & 0x6) == 0 && !shuttle.points["#{x+1},#{y+1}"] # bot right
          @ctx.fillRect px + @size - b, py + @size - b, b, b
        if (e & 0xc) == 0 && !shuttle.points["#{x-1},#{y+1}"] # bot left
          @ctx.fillRect px, py + @size - b, b, b
        
        if v is 'thinshuttle'
          k2 = if state then "#{x+state.dx},#{y+state.dy}" else k
          rid = shuttle.adjacentTo[k2]?[stateid || 0]
          if rid?
            p = @compiled.getPressure(rid)
            if p != 0
              @ctx.fillStyle = if p < 0 then 'rgba(255,0,0,0.2)' else 'rgba(0,255,0,0.15)'
              @ctx.fillRect px, py, @size, @size

    return


  drawGrid: ->
    t = if @animTime && @lastStepAt
      now = Date.now()
      exact = Math.min 1, (now - @lastStepAt) / @animTime

      ((exact * @size)|0) / @size
    else
      1

    # Draw the tiles
    #pressure = @simulator.getPressure()
    for k,v of @compiled.grid
      {x:tx,y:ty} = parseXY k
      {px, py} = @worldToScreen tx, ty
      if px+@size >= 0 and px < @canvas.width and py+@size >= 0 and py < @canvas.height
        if !@needsCompile and v in ['shuttle', 'thinshuttle']
          # Draw the blank (white) under the shuttle.
          @ctx.fillStyle = Boilerplate.colors.nothing
        else
          @ctx.fillStyle = Boilerplate.colors[v]
        @ctx.fillRect px, py, @size, @size

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

    for _,sid in @compiled.ast.shuttles
      @drawShuttle t, sid

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

      return
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

