[English](README.md) | [Русский](README.ru.md) | [繁體中文](README.zh-TW.md) | **简体中文**

# ParacosmShader

适用于 [Radiance](https://github.com/Minecraft-Radiance)（MCVR，Minecraft 的 Vulkan 光线追踪模组）的路径追踪光影包。
它改自 Radiance 内置的 **Advanced** 光影包，在光影列表中显示为 **Paracosm Shader**。

ParacosmShader 是两人合作的项目，结合了 TimON 的 Advanced Sunlit，以及 Akiraoo 的
[Chromance-VKPT](https://github.com/Akiraoo/Chromance-VKPT) 的部分内容。

## 特色

- **日光与天空**：强烈的直射阳光（正午太阳与天空约 5:1）、更柔和的黄金时刻、更清澈偏蓝的远景雾气，以及边缘柔和、
  带有临边昏暗的圆形太阳。
- **夜空**：自制的星星、星云与遥远星系，会随日月一起转动；寒冷生物群系（或每晚）会出现极光。
- **云**：体积云，以及高空一层薄薄的卷云。
- **水**：平静、带细小涟漪的水面，清澈的浅水绿松石色、焦散，深水会逐渐变成深蓝。
- **方块光源**：发光方块有两种照明模式：
  - **ReSTIR**（默认）：光照平滑，会跨帧、跨像素复用。
  - **RIS**：Chromance 的光源采样方式，没有历史累积，光照不会延迟或拖影。
- **发光方块**：岩浆块、发光的红石矿石、发光地衣各自有亮度设置；生物的发光眼睛不再消失。
- **线性材质颜色**：材质与生物群系颜色会从 sRGB 解码，保留原本的对比度，不会灰蒙蒙的。
- **第一人称身体**（可选）、带光束与星星的**末地**天空，以及**后期处理**（对比度、锐化、饱和度、自然饱和度）。

详细的更新日志（俄文）请见 [README.ru.md](README.ru.md)。

## 需求

- Minecraft 1.21.4（Fabric）
- Radiance（MCVR）0.1.6
- 支持硬件光线追踪的显卡（推荐 NVIDIA RTX；搭配 DLSS Ray Reconstruction 画面最干净）

## 安装

1. 从 [Releases](https://github.com/Akiraoo/ParacosmShader/releases) 下载光影包（或 clone 这个仓库），放到
   `<Minecraft 实例>/shaderpacks/`。文件夹或 zip 都可以。
2. 进入游戏后打开 Radiance 的设置，到光影包页面选择 **Paracosm Shader**。
3. 更新光影包后，请在光影设置页点击 **全部重置**。Radiance 会在第一次加载光影包时记住所有设置值，
   所以新的默认值需要重置后才会生效。

## 参与开发

改动一律通过 Pull Request：从 `main` 新建一个分支，改完后发起 Pull Request，由另一位维护者在游戏中测试后再合并。

## 致谢

- **TimON**（[Tarry665](https://github.com/Tarry665)）：Advanced Sunlit — 日光、天空、夜空、极光、水、云、末地天空、
  第一人称身体、后期处理。
- **Akiraoo**（[Akiraoo](https://github.com/Akiraoo)）：Chromance-VKPT — RIS 光源采样方式与云的相关内容。
- **Radiance 团队**：Radiance 模组，以及本光影包所基于的内置 Advanced 光影包。

## 许可证

[GNU General Public License v3.0](LICENSE)，与所基于的 Advanced 光影包相同。
