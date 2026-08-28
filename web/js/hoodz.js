/* ============================================================================
   HOOD — landing page behaviour
   Zero dependencies. Everything degrades gracefully without JS.
   Mirrors the Olympus interaction set: scroll reveals, parallaxed decorative
   objects, rolling stat counters, height-animated FAQ, sticky nav, marquee.
   ========================================================================== */
(function () {
  'use strict';

  var reduceMotion = window.matchMedia &&
    window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  /* ------------------------------------------------------------ helpers */
  function $(sel, ctx) { return (ctx || document).querySelector(sel); }
  function $$(sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); }

  function clamp(v, lo, hi) { return v < lo ? lo : v > hi ? hi : v; }

  /* rAF throttle for scroll handlers */
  function onScroll(fn) {
    var ticking = false;
    function handler() {
      if (ticking) return;
      ticking = true;
      window.requestAnimationFrame(function () { fn(); ticking = false; });
    }
    window.addEventListener('scroll', handler, { passive: true });
    window.addEventListener('resize', handler, { passive: true });
    handler();
  }

  /* ============================================================ 1. reveal */
  /* .slide-in / .rise-in gain .is-visible when they enter the viewport,
     staggered by their position within the same parent. */
  function initReveal() {
    var targets = $$('.slide-in, .rise-in');
    if (!targets.length) return;

    if (reduceMotion || !('IntersectionObserver' in window)) {
      targets.forEach(function (el) { el.classList.add('is-visible'); });
      return;
    }

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (entry) {
        if (!entry.isIntersecting) return;
        var el = entry.target;
        var explicit = parseInt(el.getAttribute('data-delay') || '', 10);
        var delay = isNaN(explicit) ? indexWithinParent(el) * 90 : explicit;
        window.setTimeout(function () { el.classList.add('is-visible'); }, delay);
        io.unobserve(el);
      });
    }, { rootMargin: '0px 0px -12% 0px', threshold: 0.08 });

    targets.forEach(function (el) { io.observe(el); });

    function indexWithinParent(el) {
      if (!el.parentElement) return 0;
      var sibs = Array.prototype.filter.call(el.parentElement.children, function (c) {
        return c.classList.contains('slide-in') || c.classList.contains('rise-in');
      });
      return clamp(sibs.indexOf(el), 0, 6);
    }
  }

  /* ========================================================== 2. counters */
  /* data-count-to / data-count-prefix / data-count-format="int|dec2" */
  function initCounters() {
    var nodes = $$('[data-count-to]');
    if (!nodes.length) return;

    function format(value, fmt, prefix) {
      var s;
      if (fmt === 'dec2') {
        s = value.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',');
      } else {
        s = Math.round(value).toLocaleString('en-US');
      }
      return (prefix || '') + s;
    }

    function run(el) {
      var to = parseFloat(el.getAttribute('data-count-to'));
      var fmt = el.getAttribute('data-count-format') || 'int';
      var prefix = el.getAttribute('data-count-prefix') || '';
      if (isNaN(to)) return;

      if (reduceMotion) { el.textContent = format(to, fmt, prefix); return; }

      var dur = 1600, start = null;
      function step(ts) {
        if (start === null) start = ts;
        var p = clamp((ts - start) / dur, 0, 1);
        // expo-out — the same curve as the CSS easing
        var eased = p === 1 ? 1 : 1 - Math.pow(2, -10 * p);
        el.textContent = format(to * eased, fmt, prefix);
        if (p < 1) window.requestAnimationFrame(step);
      }
      window.requestAnimationFrame(step);
    }

    if (!('IntersectionObserver' in window)) { nodes.forEach(run); return; }

    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) return;
        run(e.target);
        io.unobserve(e.target);
      });
    }, { threshold: 0.4 });
    nodes.forEach(function (el) { io.observe(el); });
  }

  /* ========================================================== 3. parallax */
  function initParallax() {
    if (reduceMotion) return;
    var items = $$('[data-parallax]');
    if (!items.length) return;

    onScroll(function () {
      var vh = window.innerHeight;
      items.forEach(function (el) {
        var rect = el.getBoundingClientRect();
        if (rect.bottom < -200 || rect.top > vh + 200) return;
        var factor = parseFloat(el.getAttribute('data-parallax')) || 0.1;
        // -1 (below the fold) … +1 (above it)
        var progress = (vh / 2 - (rect.top + rect.height / 2)) / vh;
        var shift = progress * factor * 260;
        el.style.transform = 'translate3d(0,' + shift.toFixed(2) + 'px,0)';
      });
    });
  }

  /* ============================================================== 4. FAQ */
  function initFaq() {
    $$('.faq-dd').forEach(function (item) {
      var toggle = $('.faq-dd__toggle', item);
      var panel = $('.faq-dd__list', item);
      if (!toggle || !panel) return;

      toggle.addEventListener('click', function () {
        var isOpen = item.getAttribute('data-open') === 'true';
        // accordion behaviour — close the siblings
        $$('.faq-dd').forEach(function (other) {
          if (other === item) return;
          other.setAttribute('data-open', 'false');
          var ot = $('.faq-dd__toggle', other);
          var op = $('.faq-dd__list', other);
          if (ot) ot.setAttribute('aria-expanded', 'false');
          if (op) op.style.height = '0px';
        });

        if (isOpen) {
          item.setAttribute('data-open', 'false');
          toggle.setAttribute('aria-expanded', 'false');
          panel.style.height = '0px';
        } else {
          item.setAttribute('data-open', 'true');
          toggle.setAttribute('aria-expanded', 'true');
          panel.style.height = panel.scrollHeight + 'px';
        }
      });
    });

    // keep an open panel correctly sized when the viewport changes
    window.addEventListener('resize', function () {
      $$('.faq-dd[data-open="true"] .faq-dd__list').forEach(function (p) {
        p.style.height = p.scrollHeight + 'px';
      });
    }, { passive: true });
  }

  /* ============================================================== 5. nav */
  function initNav() {
    var bar = $('#navbar');
    var burger = $('#nav-burger');
    var menu = $('#nav-menu');

    if (bar) {
      onScroll(function () {
        // the hero is ~18vw tall below the fold; stick once we clear the fold
        var stuck = window.scrollY > window.innerHeight * 0.55;
        bar.classList.toggle('is-stuck', stuck);
      });
    }

    if (burger && menu) {
      burger.addEventListener('click', function () {
        var open = menu.getAttribute('data-open') === 'true';
        menu.setAttribute('data-open', open ? 'false' : 'true');
        burger.setAttribute('aria-expanded', open ? 'false' : 'true');
        burger.setAttribute('aria-label', open ? 'Open menu' : 'Close menu');
        document.body.style.overflow = open ? '' : 'hidden';
      });

      // close on nav click or Escape
      $$('a', menu).forEach(function (a) {
        a.addEventListener('click', function () {
          menu.setAttribute('data-open', 'false');
          burger.setAttribute('aria-expanded', 'false');
          document.body.style.overflow = '';
        });
      });
      document.addEventListener('keydown', function (e) {
        if (e.key !== 'Escape') return;
        if (menu.getAttribute('data-open') !== 'true') return;
        menu.setAttribute('data-open', 'false');
        burger.setAttribute('aria-expanded', 'false');
        burger.focus();
        document.body.style.overflow = '';
      });
    }

    // the GOVERNANCE dropdown is CSS-driven on hover; make it keyboard-usable
    $$('.nav-bar__dd__toggle').forEach(function (btn) {
      btn.addEventListener('click', function () {
        var expanded = btn.getAttribute('aria-expanded') === 'true';
        btn.setAttribute('aria-expanded', expanded ? 'false' : 'true');
        var wrap = btn.parentElement;
        if (wrap) wrap.classList.toggle('is-open', !expanded);
      });
    });
  }

  /* =========================================================== 6. ticker */
  function initTicker() {
    var track = $('#ticker-track');
    if (!track) return;
    // duplicate the content once so the -50% keyframe loops seamlessly
    track.innerHTML += track.innerHTML;
  }

  /* ====================================================== 7. newsletter */
  function initNewsletter() {
    var form = $('#newsletter');
    if (!form) return;
    form.addEventListener('submit', function (e) {
      e.preventDefault();
      var input = $('#nl-email', form);
      var btn = $('.footer__form-submit', form);
      if (!input || !btn) return;
      var ok = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(input.value.trim());
      var original = btn.textContent;
      btn.textContent = ok ? 'Thanks' : 'Invalid';
      if (ok) { input.value = ''; }
      window.setTimeout(function () { btn.textContent = original; }, 2200);
    });
  }

  /* ============================================================== 8. tabs */
  /* [data-tabs] with role="tab" buttons and role="tabpanel" panels.
     Arrow keys move between tabs, matching the WAI-ARIA tabs pattern. */
  function initTabs() {
    $$('[data-tabs]').forEach(function (group) {
      var tabs = $$('[role="tab"]', group);
      var panels = $$('[role="tabpanel"]', group);
      if (!tabs.length) return;

      function select(i) {
        tabs.forEach(function (t, n) {
          var on = n === i;
          t.setAttribute('aria-selected', on ? 'true' : 'false');
          t.setAttribute('tabindex', on ? '0' : '-1');
        });
        panels.forEach(function (p, n) {
          if (n === i) { p.removeAttribute('hidden'); }
          else { p.setAttribute('hidden', ''); }
        });
        // newly shown panels have never intersected — reveal them immediately
        $$('.slide-in, .rise-in', panels[i]).forEach(function (el) {
          el.classList.add('is-visible');
        });
      }

      tabs.forEach(function (tab, i) {
        tab.setAttribute('tabindex', tab.getAttribute('aria-selected') === 'true' ? '0' : '-1');
        tab.addEventListener('click', function () { select(i); });
        tab.addEventListener('keydown', function (e) {
          var next = null;
          if (e.key === 'ArrowRight') next = (i + 1) % tabs.length;
          else if (e.key === 'ArrowLeft') next = (i - 1 + tabs.length) % tabs.length;
          else if (e.key === 'Home') next = 0;
          else if (e.key === 'End') next = tabs.length - 1;
          if (next === null) return;
          e.preventDefault();
          select(next);
          tabs[next].focus();
        });
      });
    });
  }

  /* ======================================================== 8b. docs TOC */
  /* Highlights the table-of-contents entry for the section currently on screen. */
  function initDocsToc() {
    var links = $$('.docs-toc__links a');
    if (!links.length || !('IntersectionObserver' in window)) return;

    var byId = {};
    links.forEach(function (a) {
      var id = (a.getAttribute('href') || '').slice(1);
      if (id) byId[id] = a;
    });

    var visible = {};
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) { visible[e.target.id] = e.isIntersecting; });
      // the topmost section still intersecting wins
      var current = null;
      Object.keys(byId).forEach(function (id) {
        if (current === null && visible[id]) current = id;
      });
      links.forEach(function (a) {
        a.classList.toggle('is-current', a.getAttribute('href') === '#' + current);
      });
    }, { rootMargin: '-12% 0px -70% 0px', threshold: 0 });

    Object.keys(byId).forEach(function (id) {
      var sec = document.getElementById(id);
      if (sec) io.observe(sec);
    });
  }

  /* ================================================ 9. smooth anchor jump */
  function initAnchors() {
    $$('a[href^="#"]').forEach(function (a) {
      var id = a.getAttribute('href');
      if (!id || id === '#') return;
      a.addEventListener('click', function (e) {
        var target = document.getElementById(id.slice(1));
        if (!target) return;                 // placeholder anchors: do nothing
        e.preventDefault();
        target.scrollIntoView({
          behavior: reduceMotion ? 'auto' : 'smooth',
          block: 'start'
        });
        history.replaceState(null, '', id);
      });
    });
  }

  /* ------------------------------------------------------------- boot */
  function boot() {
    initReveal();
    initCounters();
    initParallax();
    initFaq();
    initNav();
    initTicker();
    initNewsletter();
    initTabs();
    initDocsToc();
    initAnchors();
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot);
  } else {
    boot();
  }
})();
