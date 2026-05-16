(function () {
  document.querySelectorAll('a[data-contact]').forEach(function (el) {
    function reveal() { el.href = 'mailto:' + atob(el.dataset.contact); }
    el.addEventListener('mouseenter', reveal);
    el.addEventListener('focusin', reveal);
    el.addEventListener('touchstart', reveal, { passive: true });
  });
})();
