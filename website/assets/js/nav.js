(function () {
  var header = document.querySelector('.site-header');
  var btn = header && header.querySelector('.menu-toggle');
  if (!header || !btn) return;
  btn.addEventListener('click', function () {
    var open = btn.getAttribute('aria-expanded') === 'true';
    btn.setAttribute('aria-expanded', String(!open));
    header.classList.toggle('is-open', !open);
  });
})();
