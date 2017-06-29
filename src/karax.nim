## Karax -- Single page applications for Nim.

import kdom, vdom, jstrutils, compact, jdict, vstyles

export kdom.Event

proc kout*[T](x: T) {.importc: "console.log", varargs.}
  ## the preferred way of debugging karax applications.

proc hasProp(e: Node; prop: cstring): bool {.importcpp: "(#.hasOwnProperty(#))".}
proc rawkey(e: Node): VKey {.importcpp: "#.karaxKey", nodecl.}
proc key*(e: Node): VKey =
  if e.hasProp"karaxKey": result = e.rawkey
  else: result = -1
proc `key=`*(e: Node; x: VKey) {.importcpp: "#.karaxKey = #", nodecl.}

type
  PatchKind = enum
    pkReplace, pkRemove, pkAppend, pkInsertBefore
  Patch = object
    k: PatchKind
    parent, current: Node
    n: VNode

type
  KaraxInstance* = ref object ## underlying karax instance. Usually you don't have
                              ## know about this.
    rootId: cstring not nil
    renderer: proc (): VNode {.closure.}
    currentTree: VNode
    postRenderCallback: proc ()
    toFocus: Node
    toFocusV: VNode
    renderId: int
    patches: seq[Patch] # we reuse this to save allocations
    patchLen: int


var
  kxi*: KaraxInstance ## The current Karax instance. This is always used
                      ## as the default. **Note**: Within the karax DSL
                      ## always a symbol of the name *kxi* is assumed, so
                      ## if you have a local karax instance to use instead
                      ## in your 'buildHtml' statement, it needs to be named
                      ## 'kxi'.

proc setFocus*(n: VNode; enabled = true; kxi: KaraxInstance = kxi) =
  if enabled:
    kxi.toFocusV = n

# ----------------- event wrapping ---------------------------------------

template nativeValue(ev): cstring = cast[Element](ev.target).value
template setNativeValue(ev, val) = cast[Element](ev.target).value = val

template keyeventBody() =
  n.value = nativeValue(ev)
  action(ev, n)
  setNativeValue(ev, n.value)
  # Do not call redraw() here! That is already done
  # by ``karax.addEventHandler``.

proc wrapEvent(d: Node; n: VNode; k: EventKind;
               action: EventHandler): NativeEventHandler =
  proc stdWrapper(): NativeEventHandler =
    let action = action
    let n = n
    result = proc (ev: Event) =
      if n.kind == VNodeKind.textarea or n.kind == VNodeKind.input:
        keyeventBody()
      else: action(ev, n)

  proc enterWrapper(): NativeEventHandler =
    let action = action
    let n = n
    result = proc (ev: Event) =
      if ev.keyCode == 13: keyeventBody()

  proc laterWrapper(): NativeEventHandler =
    let action = action
    let n = n
    var timer: Timeout
    result = proc (ev: Event) =
      proc wrapper() = keyeventBody()
      if timer != nil: clearTimeout(timer)
      timer = setTimeout(wrapper, 400)

  case k
  of EventKind.onkeyuplater:
    result = laterWrapper()
    d.addEventListener("keyup", result)
  of EventKind.onkeyupenter:
    result = enterWrapper()
    d.addEventListener("keyup", result)
  else:
    result = stdWrapper()
    d.addEventListener(toEventName[k], result)

# --------------------- DOM diff -----------------------------------------

template detach(n: VNode) =
  if n.kind == VNodeKind.component:
    let x = VComponent(n)
    if x.onDetachImpl != nil: x.onDetachImpl(x)
  n.dom = nil
template attach(n: VNode) =
  n.dom = result

proc applyEvents(n: VNode; kxi: KaraxInstance) =
  let dest = n.dom
  for i in 0..<len(n.events):
    n.events[i][2] = wrapEvent(dest, n, n.events[i][0], n.events[i][1])

proc vnodeToDom(n: VNode; kxi: KaraxInstance): Node =
  if n.kind == VNodeKind.text:
    result = document.createTextNode(n.text)
    attach n
  elif n.kind == VNodeKind.vthunk:
    let x = callThunk(vcomponents[n.text], n)
    result = vnodeToDom(x, kxi)
    #n.key = result.key
    attach n
    return result
  elif n.kind == VNodeKind.dthunk:
    result = callThunk(dcomponents[n.text], n)
    #n.key = result.key
    attach n
    return result
  elif n.kind == VNodeKind.component:
    let x = VComponent(n)
    if x.onAttachImpl != nil: x.onAttachImpl(x)
    assert x.renderImpl != nil
    if x.expanded == nil:
      x.expanded = x.renderImpl(x)
      x.updatedImpl(x)
    result = vnodeToDom(x.expanded, kxi)
    attach n
    return result
  else:
    result = document.createElement(toTag[n.kind])
    attach n
    for k in n:
      appendChild(result, vnodeToDom(k, kxi))
    # text is mapped to 'value':
    if n.text != nil:
      result.value = n.text
  if n.id != nil:
    result.id = n.id
  if n.class != nil:
    result.class = n.class
  #if n.key >= 0:
  #  result.key = n.key
  for k, v in attrs(n):
    if v != nil:
      result.setAttr(k, v)
  applyEvents(n, kxi)
  if n == kxi.toFocusV and kxi.toFocus.isNil:
    kxi.toFocus = result
  if not n.style.isNil: applyStyle(result, n.style)

proc same(n: VNode, e: Node): bool =
  if n.kind == VNodeKind.component:
    result = same(VComponent(n).expanded, e)
  elif toTag[n.kind] == e.nodename:
    result = true
    if n.kind != VNodeKind.text:
      if e.len != n.len:
        kout e.len, n.len
        return false
      for i in 0 ..< n.len:
        if not same(n[i], e[i]): return false
  else:
    kout toTag[n.kind], e.nodename

proc replaceById(id: cstring; newTree: Node) =
  let x = document.getElementById(id)
  x.parentNode.replaceChild(newTree, x)

type
  EqResult = enum
    changed, different, similar, identical

proc eq(a, b: VNode): EqResult =
  if a.kind != b.kind: return different
  if a.id != b.id: return different
  result = identical
  if a.key != b.key: return different
  if a.kind == VNodeKind.text:
    if a.text != b.text: return different
  elif a.kind == VNodeKind.vthunk or a.kind == VNodeKind.dthunk:
    if a.text != b.text: return different
    if a.len != b.len: return different
    for i in 0..<a.len:
      if eq(a[i], b[i]) == different: return different
  elif b.kind == VNodeKind.component:
    # different component names mean different components:
    if a.text != b.text: return different
    let x = VComponent(b)
    assert x.changedImpl != nil
    return if x.changedImpl(x): changed else: identical
  if not sameAttrs(a, b): return different
  if a.class != b.class: return different
  if not eq(a.style, b.style): return similar
  # Do not test event listeners here!
  return result

proc updateStyles(newNode, oldNode: VNode) =
  # we keep the oldNode, but take over the style from the new node:
  if oldNode.dom != nil:
    if newNode.style != nil: applyStyle(oldNode.dom, newNode.style)
    else: oldNode.dom.style = Style()
  oldNode.style = newNode.style

proc mergeEvents(newNode, oldNode: VNode; kxi: KaraxInstance) =
  let d = oldNode.dom
  if d != nil:
    for i in 0..<oldNode.events.len:
      let k = oldNode.events[i][0]
      let name = case k
                of EventKind.onkeyuplater, EventKind.onkeyupenter: cstring"keyup"
                else: toEventName[k]
      d.removeEventListener(name, oldNode.events[i][2])
  shallowCopy(oldNode.events, newNode.events)
  applyEvents(oldNode, kxi)

proc printV(n: VNode; depth: cstring = "") =
  kout depth, cstring($n.kind), cstring"key ", n.key
  #for k, v in pairs(n.style):
  #  kout depth, "style: ", k, v
  if n.kind == VNodeKind.component:
    let nn = VComponent(n)
    if nn.expanded != nil: printV(nn.expanded, ">>" & depth)
  elif n.kind == VNodeKind.text:
    kout depth, n.text
  for i in 0 ..< n.len:
    printV(n[i], depth & "  ")

template addPatch(kxi: KaraxInstance; ka: PatchKind; parenta, currenta: Node;
              na: VNode) =
  let L = kxi.patchLen
  if L >= kxi.patches.len:
    # allocate more space:
    kxi.patches.add(Patch(k: ka, parent: parenta, current: currenta, n: na))
  else:
    kxi.patches[L].k = ka
    kxi.patches[L].parent = parenta
    kxi.patches[L].current = currenta
    kxi.patches[L].n = na
  inc kxi.patchLen

proc apply(kxi: KaraxInstance) =
  for i in 0..<kxi.patchLen:
    let p = kxi.patches[i]
    case p.k
    of pkReplace:
      let nn = vnodeToDom(p.n, kxi)
      if p.parent == nil:
        replaceById(kxi.rootId, nn)
      else:
        p.parent.replaceChild(nn, p.current)
    of pkRemove:
      p.parent.removeChild(p.current)
    of pkAppend:
      let nn = vnodeToDom(p.n, kxi)
      p.parent.appendChild(nn)
    of pkInsertBefore:
      let nn = vnodeToDom(p.n, kxi)
      p.parent.insertBefore(nn, p.current)
  kxi.patchLen = 0

proc diff(newNode, oldNode: VNode; parent, current: Node; kxi: KaraxInstance): EqResult =
  result = eq(newNode, oldNode)
  case result
  of identical, similar:
    newNode.dom = oldNode.dom
    if result == similar: updateStyles(newNode, oldNode)
    if newNode.events.len != 0 or oldNode.events.len != 0:
      mergeEvents(newNode, oldNode, kxi)
    #if newNode.kind == VNodeKind.input or newNode.kind == VNodeKind.textarea:
    #  oldNode.dom.value = newNode.text

    let newLength = newNode.len
    var oldLength = oldNode.len
    let minLength = min(newLength, oldLength)
    if newLength == 0 and oldLength == 0: return result

    assert oldNode.kind == newNode.kind
    var commonPrefix = 0

    template eqAndUpdate(a: VNode; i: int; b: VNode; j: int; info, action: untyped) =
      let oldLen = kxi.patchLen
      when false:
        if oldNode.kind notin {VNodeKind.component, VNodeKind.vthunk, VNodeKind.dthunk}:
          assert current != nil
          assert current.childNodes[j] != nil, $info
          assert oldNode.len == current.len

      let r = if oldNode.kind == VNodeKind.component or oldNode.kind == VNodeKind.vthunk or
                 oldNode.kind == VNodeKind.dthunk:
                diff(a[i], b[j], parent, current, kxi)
              else:
                diff(a[i], b[j], current, current.childNodes[j], kxi)
      case r
      of identical, changed, similar:
        a[i] = b[j]
        action
      of different:
        # undo what 'diff' would have done:
        kxi.patchLen = oldLen
        if result != different: result = r
        break
      #of similar:
      #  updateStyles(a[i], b[j])
      #  a[i] = b[j]
      #  action

    while commonPrefix < minLength:
      eqAndUpdate(newNode, commonPrefix, oldNode, commonPrefix, cstring"prefix"):
        inc commonPrefix

    var oldPos = oldLength - 1
    var newPos = newLength - 1
    while oldPos >= commonPrefix and newPos >= commonPrefix:
      eqAndUpdate(newNode, newPos, oldNode, oldPos, cstring"suffix"):
        dec oldPos
        dec newPos

    var pos = min(oldPos, newPos) + 1
    for i in commonPrefix..pos-1:
      if diff(newNode[i], oldNode[i], current, current.childNodes[i],
              kxi) != different:
        newNode[i] = oldNode[i]
      else:
        result = different

    if oldPos + 1 == oldLength:
      for i in pos..newPos:
        kxi.addPatch(pkAppend, current, nil, newNode[i])
        result = different
    else:
      let before = current.childNodes[oldPos + 1]
      for i in pos..newPos:
        kxi.addPatch(pkInsertBefore, current, before, newNode[i])
        result = different
    # XXX call 'attach' here?
    for i in pos..oldPos:
      detach(oldNode[i])
      #doAssert i < current.childNodes.len
      kxi.addPatch(pkRemove, current, current.childNodes[i], nil)
      result = different

  of changed:
    assert oldNode.kind == VNodeKind.component
    let x = VComponent(oldNode)
    let oldExpanded = x.expanded
    x.expanded = x.renderImpl(x)
    x.updatedImpl(x)
    if oldExpanded == nil:
      detach(oldNode)
      kxi.addPatch(pkReplace, parent, current, x.expanded)
    else:
      let res = diff(x.expanded, oldExpanded, parent, current, kxi)
      if res != different:
        x.expanded = oldExpanded
        assert oldExpanded.dom != nil, "old expanded.dom is nil"
      else:
        assert x.expanded.dom != nil, "expanded.dom is nil"
  of different:
    detach(oldNode)
    kxi.addPatch(pkReplace, parent, current, newNode)

proc dodraw(kxi: KaraxInstance) =
  if kxi.renderer.isNil: return
  let newtree = kxi.renderer()
  newtree.id = kxi.rootId
  kxi.toFocus = nil
  if kxi.currentTree == nil:
    kxi.currentTree = newtree
    let asdom = vnodeToDom(kxi.currentTree, kxi)
    replaceById(kxi.rootId, asdom)
  else:
    let olddom = document.getElementById(kxi.rootId)
    discard diff(newtree, kxi.currentTree, nil, olddom, kxi)
    #kout cstring"patch len ", patches.len
    apply(kxi)
    kxi.currentTree = newtree
  #doAssert same(kxi.currentTree, document.getElementById(kxi.rootId))

  if not kxi.postRenderCallback.isNil:
    kxi.postRenderCallback()

  # now that it's part of the DOM, give it the focus:
  if kxi.toFocus != nil:
    kxi.toFocus.focus()
  kxi.renderId = 0

proc reqFrame(callback: proc()): int {.importc: "window.requestAnimationFrame".}
proc cancelFrame(id: int) {.importc: "window.cancelAnimationFrame".}

proc redraw*(kxi: KaraxInstance = kxi) =
  # we buffer redraw requests:
  when false:
    if drawTimeout != nil:
      clearTimeout(drawTimeout)
    drawTimeout = setTimeout(dodraw, 30)
  elif true:
    if kxi.renderId == 0:
      kxi.renderId = reqFrame(proc () = kxi.dodraw)
  else:
    dodraw(kxi)

proc redrawSync*(kxi: KaraxInstance = kxi) = dodraw(kxi)

proc init(ev: Event) =
  kxi.renderId = reqFrame(proc () = kxi.dodraw)

proc setRenderer*(renderer: proc (): VNode, root: cstring = "ROOT",
                  clientPostRenderCallback: proc () = nil): KaraxInstance {.discardable.} =
  ## Setup Karax. Usually the return value can be ignored.
  result = KaraxInstance(rootId: root, renderer: renderer,
                         postRenderCallback: clientPostRenderCallback,
                         patches: newSeq[Patch](60))
  kxi = result
  window.onload = init

proc addEventHandler*(n: VNode; k: EventKind; action: EventHandler;
                      kxi: KaraxInstance = kxi) =
  ## Implements the foundation of Karax's event management.
  ## Karax DSL transforms ``tag(onEvent = handler)`` to
  ## ``tempNode.addEventHandler(tagNode, EventKind.onEvent, wrapper)``
  ## where ``wrapper`` calls the passed ``action`` and then triggers
  ## a ``redraw``.
  proc wrapper(ev: Event; n: VNode) =
    action(ev, n)
    redraw(kxi)
  addEventListener(n, k, wrapper)

proc setOnHashChange*(action: proc (hashPart: cstring)) =
  var onhashChange {.importc: "window.onhashchange".}: proc()
  var hashPart {.importc: "window.location.hash".}: cstring
  proc wrapper() =
    action(hashPart)
    redraw()
  onhashchange = wrapper

{.push stackTrace:off.}

proc setupErrorHandler*() =
  ## Installs an error handler that transforms native JS unhandled
  ## exceptions into Nim based stack traces. If `useAlert` is false,
  ## the error message is put into the console, otherwise `alert`
  ## is called.
  proc stackTraceAsCstring(): cstring = cstring(getStackTrace())
  var onerror {.importc: "window.onerror", used.} =
    proc (msg, url: cstring, line, col: int, error: cstring): bool =
      var x = cstring"Error: " & msg & "\n" & stackTraceAsCstring()
      kout(x)
      return true # suppressErrorAlert
{.pop.}

proc prepend(parent, kid: Element) =
  parent.insertBefore(kid, parent.firstChild)

proc loadScript*(jsfilename: cstring; kxi: KaraxInstance = kxi) =
  let body = document.getElementById("body")
  let s = document.createElement("script")
  s.setAttr "type", "text/javascript"
  s.setAttr "src", jsfilename
  body.prepend(s)
  redraw(kxi)
