// script.js
export function setupSelfResponsibilityToggle() {
  const button = document.getElementById('a1');
  const b2Section = document.getElementById('b2');
  const tocList = document.querySelector("#toc ul");
  let isVisible = false;

  if (!button || !b2Section) return;

  function createB2TocItem() {
    const li = document.createElement("li");
    const a = document.createElement("a");
    a.href = "#b2";
    a.textContent = "自己責任アプリ一覧";
    li.appendChild(a);
    li.id = "toc-b2";
    return li;
  }

  button.addEventListener('click', () => {
    if (!isVisible) {
      const shouldShow = confirm('この内容を表示しますか？自己責任で利用してください。');
      if (!shouldShow) return;
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
  });
}
