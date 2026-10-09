# 用 Sprout Day 打開邀請

<p id="invite-code-block" hidden>你的邀請碼：<strong id="invite-code"></strong></p>

<p id="invite-open" hidden><a id="invite-open-link" href="sproutday://invite">在已安裝的 Sprout Day 中打開邀請</a></p>

<p id="invite-fallback">請從家人傳給你的邀請連結進入本頁；若沒有看到邀請碼，也可以在 Sprout Day 的「加入家庭」畫面直接貼上整個連結。</p>

還沒有安裝 Sprout Day？App Store 連結：_上架後補_（LS-8；佔位）。

<script>
(function () {
  var code = null;
  var fromPath = location.pathname.match(/^\/invite\/([A-Za-z0-9]+)\/?$/);
  var fromQuery = new URLSearchParams(location.search).get("code");
  var raw = fromPath ? fromPath[1] : fromQuery;
  if (raw && /^[A-Za-z0-9]{3,12}$/.test(raw)) { code = raw.toUpperCase(); }
  if (!code) { return; }
  document.getElementById("invite-code").textContent = code;
  document.getElementById("invite-open-link").href = "sproutday://invite/" + code;
  document.getElementById("invite-code-block").hidden = false;
  document.getElementById("invite-open").hidden = false;
  document.getElementById("invite-fallback").hidden = true;
})();
</script>
