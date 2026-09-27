document.querySelectorAll(".copy").forEach(function (btn) {
  btn.addEventListener("click", function () {
    var text = btn.getAttribute("data-copy");
    var label = btn.textContent;
    function done(msg) { btn.textContent = msg; setTimeout(function () { btn.textContent = label; }, 1600); }
    function fallback() {
      var pre = btn.parentElement.querySelector("pre, code");
      if (pre) {
        var r = document.createRange(); r.selectNodeContents(pre);
        var s = window.getSelection(); s.removeAllRanges(); s.addRange(r);
        done("Selected, press Ctrl+C");
      }
    }
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { done("Copied"); }, fallback);
    } else { fallback(); }
  });
});

var tabs = Array.prototype.slice.call(document.querySelectorAll(".tab"));
function select(tab) {
  tabs.forEach(function (t) {
    var on = t === tab;
    t.setAttribute("aria-selected", on ? "true" : "false");
    t.tabIndex = on ? 0 : -1;
    document.getElementById(t.getAttribute("aria-controls")).hidden = !on;
  });
}
tabs.forEach(function (t, i) {
  t.tabIndex = i === 0 ? 0 : -1;
  t.addEventListener("click", function () { select(t); });
  t.addEventListener("keydown", function (e) {
    if (e.key === "ArrowRight" || e.key === "ArrowLeft") {
      var n = tabs[(i + (e.key === "ArrowRight" ? 1 : tabs.length - 1)) % tabs.length];
      select(n); n.focus(); e.preventDefault();
    }
  });
});
