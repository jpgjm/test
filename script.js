const button = document.getElementById('a1');
const b2Section = document.getElementById('b2');
const tocList = document.querySelector("#toc ul");
let isVisible = false;

// 目次に追加するアイテムを生成する関数
function createB2TocItem() {
  const li = document.createElement("li");
  const a = document.createElement("a");
  a.href = "#b2";
  a.textContent = "自己責任アプリ一覧";
  li.appendChild(a);
  li.id = "toc-b2"; // 後で削除できるようにidをつける
  return li;
}

button.addEventListener('click', () => {
  if (!isVisible) {
    const shouldShow = confirm('この内容を表示しますか？自己責任で利用してください。');
    if (!shouldShow) {
      return; // キャンセルしたら何もしない
    }
  }
  isVisible = !isVisible;

  if (isVisible) {
    b2Section.style.display = 'block';
    button.textContent = '自己責任で利用するアプリ一覧を閉じる';

    if (!document.getElementById("toc-b2")) {
      tocList.appendChild(createB2TocItem());
    }

    b2Section.querySelectorAll("li[id]").forEach(li => {
      const liId = li.id;
      const existing = document.getElementById("toc-" + liId);
      if (!existing) {
        const tocLi = document.createElement("li");
        const tocA = document.createElement("a");
        tocA.href = "#" + liId;
        const appLink = li.querySelector("a");
        tocA.textContent = appLink ? appLink.textContent : liId;
        tocLi.appendChild(tocA);
        tocLi.id = "toc-" + liId;
        tocList.appendChild(tocLi);
      }
    });
  } else {
    b2Section.style.display = 'none';
    button.textContent = '自己責任で利用するアプリ一覧を見る';

    const tocB2 = document.getElementById("toc-b2");
    if (tocB2) tocB2.remove();

    b2Section.querySelectorAll("li[id]").forEach(li => {
      const tocLi = document.getElementById("toc-" + li.id);
      if (tocLi) tocLi.remove();
    });
  }
}); // ←ここに抜けてた「閉じ括弧」と「);」が必要




const floatingBtn = document.getElementById("floatingBtn");
const options = document.getElementById("options");
const toc = document.getElementById("toc");
const showToc = document.getElementById("showToc");

function updateButtonSymbol() {
  if (toc.style.display === "block") {
    floatingBtn.textContent = "↩︎";
  } else if (options.style.display === "block") {
    floatingBtn.textContent = "✕";
  } else {
    floatingBtn.textContent = "≡";
  }
}

floatingBtn.addEventListener("click", () => {
  const isOptionsVisible = options.style.display === "block";
  options.style.display = isOptionsVisible ? "none" : "block";
  toc.style.display = "none";
  updateButtonSymbol();
});

showToc.addEventListener("click", () => {
  const isTocVisible = toc.style.display === "block";
  toc.style.display = isTocVisible ? "none" : "block";
  options.style.display = "none";
  updateButtonSymbol();
});

document.addEventListener("click", (e) => {
  if (!e.target.closest("#floatingBtn") &&
      !e.target.closest("#options") &&
      !e.target.closest("#toc")) {
    options.style.display = "none";
    toc.style.display = "none";
    updateButtonSymbol();
  }
});

const toggleBtn = document.getElementById('toggleThemeBtn');
const body = document.body;

toggleBtn.addEventListener('click', () => {
  body.classList.toggle('dark-theme');

  // オプション: ダークモード状態をlocalStorageに保存してリロード後も記憶させる
  if (body.classList.contains('dark-theme')) {
    localStorage.setItem('theme', 'dark');
  } else {
    localStorage.setItem('theme', 'light');
  }
});

// ページ読み込み時に保存状態を反映
window.addEventListener('DOMContentLoaded', () => {
  if (localStorage.getItem('theme') === 'dark') {
    body.classList.add('dark-theme');
  }
});