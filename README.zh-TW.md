[English](README.md) | [Русский](README.ru.md) | **繁體中文** | [简体中文](README.zh-CN.md)

# ParacosmShader

給 [Radiance](https://github.com/Minecraft-Radiance)（MCVR，Minecraft 的 Vulkan 光線追蹤模組）使用的路徑追蹤光影包。
它改自 Radiance 內建的 **Advanced** 光影包，在光影清單中顯示為 **Paracosm Shader**。

ParacosmShader 是兩人合作的專案，結合了 TimON 的 Advanced Sunlit，以及 Akiraoo 的
[Chromance-VKPT](https://github.com/Akiraoo/Chromance-VKPT) 的部分內容。

## 特色

- **日光與天空**：強烈的直射陽光（正午太陽與天空約 5:1）、較柔和的黃金時刻、更清澈偏藍的遠景霧氣，以及邊緣柔和、
  帶有臨邊昏暗的圓形太陽。
- **夜空**：自製的星星、星雲與遠方星系，會隨日月一起轉動；寒冷生態域（或每晚）會出現極光。
- **雲**：體積雲，以及高空一層薄薄的卷雲。
- **水**：平靜、帶細小漣漪的水面，清澈的淺水綠松石色、焦散，深水會逐漸變成深藍。
- **方塊光源**：發光方塊有兩種照明模式：
  - **ReSTIR**（預設）：光照平滑，會跨幀、跨像素重用。
  - **RIS**：Chromance 的光源取樣方式，沒有歷史累積，光照不會延遲或拖影。
- **發光方塊**：岩漿塊、發光的紅石礦、發光地衣各自有亮度設定；生物的發光眼睛不再消失。
- **線性材質顏色**：材質與生態域顏色會從 sRGB 解碼，保留原本的對比，不會灰灰霧霧的。
- **第一人稱身體**（可選）、帶光束與星星的**終界**天空，以及**後處理**（對比、銳化、飽和度、自然飽和度）。

詳細的更新紀錄（俄文）請見 [README.ru.md](README.ru.md)。

## 需求

- Minecraft 1.21.4（Fabric）
- Radiance（MCVR）0.1.6
- 支援硬體光線追蹤的顯示卡（建議 NVIDIA RTX；搭配 DLSS Ray Reconstruction 畫面最乾淨）

## 安裝

1. 從 [Releases](https://github.com/Akiraoo/ParacosmShader/releases) 下載光影包（或 clone 這個 repo），放到
   `<Minecraft 實例>/shaderpacks/`。資料夾或 zip 都可以。
2. 進遊戲後打開 Radiance 的設定，到光影包頁面選擇 **Paracosm Shader**。
3. 更新光影包後，請在光影設定頁按 **全部重設**。Radiance 會在第一次載入光影包時記住所有設定值，
   所以新的預設值要重設後才會套用。

## 參與開發

改動一律透過 Pull Request：從 `main` 開一個分支、改完後發 Pull Request，由另一位維護者在遊戲中測試後再合併。

## 致謝

- **TimON**（[Tarry665](https://github.com/Tarry665)）：Advanced Sunlit — 日光、天空、夜空、極光、水、雲、終界天空、
  第一人稱身體、後處理。
- **Akiraoo**（[Akiraoo](https://github.com/Akiraoo)）：Chromance-VKPT — RIS 光源取樣方式與雲的相關內容。
- **Radiance 團隊**：Radiance 模組，以及本光影包所基於的內建 Advanced 光影包。

## 授權

[GNU General Public License v3.0](LICENSE)，與所基於的 Advanced 光影包相同。
