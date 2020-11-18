## This demo shows how you can develop your own stateful components with Karax.

import vdom, vstyles, karax, karaxdsl, jdict, jstrutils, kdom

type
  Carousel = ref object of VComponent
    counter: int
    cntdown: int
    timer: TimeOut
    list: seq[cstring]

const ticksUntilChange = 5

var
  images: seq[cstring] = @[cstring"a", "b", "c", "d"]

proc render(x: VComponent): VNode =
  var self = Carousel(x)
  proc getCounter(a:Carousel) :int =
    result = a.cntdown
  proc getCol(a:Carousel):cstring =
    let b = a.getCounter()
    result =
      if b == 0: cstring"#4d4d4d"
      elif b == 1: cstring"#ff00ff"
      elif b == 2: cstring"#00ffff"
      elif b == 3: cstring"#ffff00"
      else: cstring"red"
  
  proc docount() =
    dec self.cntdown
    if self.cntdown == 0:
      self.counter = (self.counter + 1) mod self.list.len
      self.cntdown = ticksUntilChange
    applyStyle(self.dom,style(StyleAttr.color, self.getCol()))
    markDirty(self)
    redraw()

  proc onclick(ev: Event; n: VNode) {.closure.}=
    if self.timer != nil:
      clearTimeout(self.timer)
    self.timer = setTimeout(docount, 30)

  result = buildHtml(tdiv()):
    text self.list[self.counter]
    button(onclick = onclick):
      text "Next"
    tdiv(style = style(StyleAttr.color, self.getCol())):
      text "This changes its color."
    if self.cntdown != ticksUntilChange:
      text &self.cntdown

proc carousel(): Carousel =
  result = newComponent(Carousel, render)
  result.list = images
  result.cntdown = ticksUntilChange

proc createDom(): VNode =
  result = buildHtml(table):
    tr:
      td:
        carousel()
      td:
        carousel()
    tr:
      td:
        carousel()
      td:
        carousel()

setRenderer createDom
