(function () {
  document.querySelectorAll('a[data-email]').forEach(function (el) {
    function reveal() { el.href = 'mailto:' + atob(el.dataset.email); }
    el.addEventListener('mouseenter', reveal);
    el.addEventListener('focusin', reveal);
    el.addEventListener('touchstart', reveal, { passive: true });
  });
})();
