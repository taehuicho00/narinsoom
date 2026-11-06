// 직원 화면 공통 왼쪽 메뉴
//  · 넓은 화면(900px 이상): 왼쪽에 항상 보이는 메뉴
//  · 휴대폰: 상단 ☰ 버튼 → 왼쪽에서 메뉴가 열림
// 메뉴 추가는 아래 MENU 배열에 한 줄 추가하면 됩니다.
(function(){
  const MENU = [
    { href: "./",              label: "입실 현황", icon: "🏠", match: p => !/(purchase|receipt)\.html$/.test(p) },
    { href: "./purchase.html", label: "구매요청",  icon: "🛒", match: p => p.endsWith("purchase.html") },
    { href: "./receipt.html",  label: "간이영수증", icon: "🧾", match: p => p.endsWith("receipt.html") },
  ];

  const css = `
  .snav{position:fixed;top:0;left:0;bottom:0;width:208px;background:var(--card);border-right:1px solid var(--line);padding:22px 12px;z-index:30;display:flex;flex-direction:column;gap:4px;transition:transform .2s}
  .snav .sbrand{font-size:12px;letter-spacing:.2em;color:var(--sub);padding:0 10px 14px}
  .snav a{display:flex;align-items:center;gap:10px;padding:11px 12px;border-radius:10px;color:var(--ink);text-decoration:none;font-weight:600;font-size:15px}
  .snav a:hover{background:var(--bg)}
  .snav a.on{background:var(--accent);color:#fff}
  .snav-bg{position:fixed;inset:0;background:rgba(0,0,0,.35);z-index:29;opacity:0;pointer-events:none;transition:opacity .2s}
  .menubtn{display:none;border:1px solid var(--line);background:var(--card);color:var(--ink);border-radius:10px;width:36px;height:36px;font-size:18px;margin-right:8px;flex:0 0 auto}
  @media (min-width:900px){ body{padding-left:208px} }
  @media (max-width:899px){
    .snav{transform:translateX(-100%);box-shadow:4px 0 20px rgba(0,0,0,.15)}
    body.nav-open .snav{transform:none}
    body.nav-open .snav-bg{opacity:1;pointer-events:auto}
    .menubtn{display:inline-flex;align-items:center;justify-content:center}
    .top{align-items:center !important}
    .top > .brand:first-of-type{flex:1}
  }
  body.locked .snav, body.locked .snav-bg, body.locked .menubtn{display:none !important}
  body.locked{padding-left:0 !important}
  @media (prefers-reduced-motion:reduce){ .snav,.snav-bg{transition:none} }`;
  const st = document.createElement("style"); st.textContent = css; document.head.appendChild(st);

  const path = location.pathname;
  const nav = document.createElement("nav");
  nav.className = "snav"; nav.setAttribute("aria-label", "직원 메뉴");
  nav.innerHTML = `<div class="sbrand">NARINSOOM</div>` + MENU.map(m =>
    `<a href="${m.href}" class="${m.match(path) ? "on" : ""}"${m.match(path) ? ' aria-current="page"' : ""}><span>${m.icon}</span>${m.label}</a>`).join("");
  const bg = document.createElement("div"); bg.className = "snav-bg";
  document.body.prepend(bg); document.body.prepend(nav);

  const btn = document.createElement("button");
  btn.className = "menubtn"; btn.type = "button"; btn.setAttribute("aria-label", "메뉴 열기"); btn.textContent = "☰";
  document.querySelectorAll(".top").forEach(t => t.prepend(btn.cloneNode(true)));
  const toggle = open => document.body.classList.toggle("nav-open", open);
  document.addEventListener("click", e => {
    if(e.target.closest(".menubtn")) return toggle(true);
    if(e.target === bg) return toggle(false);
  });
  document.addEventListener("keydown", e => { if(e.key === "Escape") toggle(false); });
})();
