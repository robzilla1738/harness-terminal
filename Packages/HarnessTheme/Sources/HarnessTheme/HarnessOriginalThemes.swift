/// The Harness collection: 25 hand-tuned palettes, with the black default preserved.
/// Kept in Swift so selecting an original never needs to decode the community catalog.
enum HarnessOriginalThemes {
    static let all: [HarnessThemeDefinition] = [
        .make(
            "Harness Default",
            bg: "#000000", fg: "#ffffff", cursor: "#ffffff",
            selectionBackground: "#333333",
            palette: [
                "#1d1f21", "#cc6666", "#b5bd68", "#f0c674",
                "#81a2be", "#b294bb", "#8abeb7", "#c5c8c6",
                "#6e6e6e", "#d54e53", "#b9ca4a", "#e7c547",
                "#7aa6da", "#c397d8", "#70c0b1", "#eaeaea",
            ]
        ),
        .make(
            "Harness Light",
            bg: "#f8f9fc", fg: "#1e2430", cursor: "#2463d1",
            selectionBackground: "#cddcf7",
            palette: [
                "#1f2533", "#c42b3c", "#2e7d32", "#9a6700",
                "#2463d1", "#8250df", "#12808a", "#d8dce5",
                "#5f6878", "#d73a49", "#3b8f40", "#a86f00",
                "#3d7ef0", "#8f5ee8", "#18858f", "#eef1f6",
            ]
        ),
        .make(
            "Harness Navy",
            bg: "#121b2d", fg: "#d5dceb", cursor: "#6fa8f5",
            selectionBackground: "#2b3d5e",
            palette: [
                "#1c2740", "#e5767f", "#9ccc83", "#e9c47f",
                "#6fa8f5", "#b392f0", "#67c6cf", "#c4ccdb",
                "#6c7b98", "#f08a92", "#b0dc98", "#f3d394",
                "#8fbcff", "#c8aaff", "#86d7df", "#eef2f8",
            ]
        ),
        .make(
            "Harness Graphite",
            bg: "#151719", fg: "#dce2e5", cursor: "#a6c4d5",
            selectionBackground: "#343d44",
            palette: [
                "#24282c", "#e58a8a", "#a6bf8e", "#dfbd83",
                "#89afd4", "#b9a0d5", "#89c2c8", "#cbd3d8",
                "#7b878f", "#f2a1a1", "#bed3a5", "#eed09e",
                "#a4c5e5", "#cfbae7", "#a6d8dc", "#f0f4f5",
            ]
        ),
        .make(
            "Harness Midnight",
            bg: "#0d1424", fg: "#d4def2", cursor: "#8eabff",
            selectionBackground: "#293758",
            palette: [
                "#18233b", "#e98b9f", "#a5c998", "#e8c78e",
                "#89a9ef", "#b4a0ed", "#7fc7d6", "#b8c8e3",
                "#7686a6", "#f5a2b3", "#bedcaf", "#f5daaa",
                "#a7bfff", "#cab8fb", "#9cdde7", "#ecf2ff",
            ]
        ),
        .make(
            "Harness Cobalt",
            bg: "#101f3a", fg: "#dae6ff", cursor: "#73b9ff",
            selectionBackground: "#26476c",
            palette: [
                "#1b2d4a", "#f08d9d", "#a0d8ac", "#f0cb86",
                "#73b9ff", "#bca4fa", "#79d6e0", "#c4d5f0",
                "#7b91b5", "#ffa8b5", "#bcebc6", "#ffdfa8",
                "#9dceff", "#d3bdff", "#9be9ee", "#f0f6ff",
            ]
        ),
        .make(
            "Harness Deep Sea",
            bg: "#00212c", fg: "#e5f0f2", cursor: "#a9cbd3",
            selectionBackground: "#264650",
            palette: [
                "#17323b", "#e58e91", "#a8c994", "#e3c28a",
                "#85b8dc", "#b2a5da", "#70cbd0", "#bed5d7",
                "#76979d", "#f3a6a8", "#c1ddaf", "#f2d7a7",
                "#a3d0ed", "#cabde9", "#94e0df", "#ecf7f5",
            ]
        ),
        .make(
            "Harness Lagoon",
            bg: "#112827", fg: "#d7ece5", cursor: "#82d6b6",
            selectionBackground: "#2a4d43",
            palette: [
                "#203b36", "#ec9990", "#b0d48f", "#e9cf8c",
                "#8cbedc", "#c7a9df", "#82d6b6", "#c0d9ce",
                "#80a196", "#f8b1a6", "#c9e8ac", "#f7e2a9",
                "#aad5ed", "#dec2f0", "#a4e9d0", "#f0fbf5",
            ]
        ),
        .make(
            "Harness Spruce",
            bg: "#13221b", fg: "#dce8db", cursor: "#9dcaa7",
            selectionBackground: "#2f4736",
            palette: [
                "#24372a", "#de9591", "#a8c990", "#dfc595",
                "#91b9c4", "#c0a5cc", "#88c7b1", "#c6d6c2",
                "#7e967f", "#edaca6", "#c1ddac", "#eed9b0",
                "#aacfd7", "#d5bbdf", "#a5dcc6", "#f2f7eb",
            ]
        ),
        .make(
            "Harness Moss",
            bg: "#20251b", fg: "#e2e7d3", cursor: "#bccb91",
            selectionBackground: "#414b30",
            palette: [
                "#313b27", "#df9990", "#b8ca8e", "#e3c98e",
                "#9dbbc2", "#c6aacb", "#9fc8af", "#ccd4bb",
                "#8c997c", "#f0b1a7", "#cfdfa9", "#f3dcaa",
                "#b7d0d5", "#dbc1dd", "#b9ddc7", "#f6f7e8",
            ]
        ),
        .make(
            "Harness Ember",
            bg: "#291b18", fg: "#f1dfd3", cursor: "#eda47e",
            selectionBackground: "#563830",
            palette: [
                "#3b2924", "#f09589", "#b8c88c", "#e8c089",
                "#9dbbd5", "#c9a3c4", "#98c5bb", "#dec9bc",
                "#a18a7c", "#ffae9d", "#cfdda5", "#f8d4a2",
                "#b7d2e6", "#dfbcda", "#b3dcd0", "#fcf1e5",
            ]
        ),
        .make(
            "Harness Copper",
            bg: "#2b211a", fg: "#ecdfca", cursor: "#ddb17b",
            selectionBackground: "#53402a",
            palette: [
                "#3c3024", "#e69c89", "#bbc790", "#e2c185",
                "#9abbd0", "#c7a6bc", "#93c7b7", "#d8cbb5",
                "#a2947d", "#f5b39f", "#d0dba8", "#f1d5a2",
                "#b4d0e1", "#ddc0d2", "#b0dcc9", "#faf1de",
            ]
        ),
        .make(
            "Harness Dune",
            bg: "#28251f", fg: "#e9e2d1", cursor: "#d0bd90",
            selectionBackground: "#4d4536",
            palette: [
                "#3a352b", "#dca294", "#c2ca9e", "#e1c592",
                "#a7bfd2", "#c5adcb", "#a6c8be", "#d5cebc",
                "#9c9686", "#efb9aa", "#d8dfb6", "#f3dab0",
                "#bed4e3", "#dcc4e0", "#beded3", "#faf6e8",
            ]
        ),
        .make(
            "Harness Aubergine",
            bg: "#251c2c", fg: "#e7dcee", cursor: "#c5a1ef",
            selectionBackground: "#493351",
            palette: [
                "#36273f", "#e998b6", "#b3cd9c", "#edc895",
                "#9fb6e7", "#c5a1ef", "#94c9cf", "#d0bddc",
                "#9984aa", "#f7b0c9", "#cae1b5", "#fbdcb0",
                "#bacbf5", "#d9bcff", "#afe0e4", "#f8effc",
            ]
        ),
        .make(
            "Harness Plum",
            bg: "#2b1c29", fg: "#f0dceb", cursor: "#e6a4cf",
            selectionBackground: "#56344d",
            palette: [
                "#3e2939", "#e99baa", "#b7cda0", "#e9c49b",
                "#a5b8e1", "#d6a5e5", "#99ccc6", "#dac0d3",
                "#a5879f", "#fab3bd", "#cde1b9", "#f8d9b4",
                "#bdcdf2", "#eac0f5", "#b3e2dc", "#fdf0f9",
            ]
        ),
        .make(
            "Harness Rosewood",
            bg: "#291d23", fg: "#eddee2", cursor: "#dba0ab",
            selectionBackground: "#50343f",
            palette: [
                "#3c2932", "#e89b9c", "#b7cba6", "#e7c5a0",
                "#a3bcd8", "#cca9d1", "#9bc9c1", "#d8c5cc",
                "#a28b96", "#f8b3b2", "#cedfbe", "#f6d9b9",
                "#bcd1e9", "#e0c1e4", "#b6ddd5", "#fbf1f4",
            ]
        ),
        .make(
            "Harness Moonstone",
            bg: "#222433", fg: "#e2e3f0", cursor: "#b1b6e5",
            selectionBackground: "#3d415d",
            palette: [
                "#303449", "#e8a0b0", "#b9cfa7", "#e7cea0",
                "#a2bbe9", "#bfb0e4", "#99cbd6", "#cbcde1",
                "#9096b0", "#f8b7c6", "#d0e2be", "#f7e1b9",
                "#bdd0f9", "#d7c9f7", "#b5e1e8", "#f4f4ff",
            ]
        ),
        .make(
            "Harness Aurora",
            bg: "#16262c", fg: "#dce9ed", cursor: "#94d8cc",
            selectionBackground: "#2c4952",
            palette: [
                "#233a43", "#eb9fac", "#b1d3a7", "#e6cf9a",
                "#99bfe7", "#bfa9e5", "#94d8cc", "#c4d7de",
                "#829da8", "#fab6bf", "#c9e7bf", "#f6e1b5",
                "#b6d4f7", "#d7c1f7", "#b0ebdf", "#f0f9fc",
            ]
        ),
        .make(
            "Harness Parchment",
            bg: "#f4eddf", fg: "#3c342b", cursor: "#866437",
            selectionBackground: "#e1d2b6",
            palette: [
                "#3c342b", "#a23e3c", "#476335", "#846017",
                "#365f8e", "#77518b", "#286a65", "#cfc5b2",
                "#756957", "#ac4943", "#516f39", "#886419",
                "#436c98", "#835b96", "#33746d", "#e7dec9",
            ]
        ),
        .make(
            "Harness Porcelain",
            bg: "#f7f4f0", fg: "#34373c", cursor: "#4e637d",
            selectionBackground: "#dce2e8",
            palette: [
                "#34373c", "#ab414b", "#42704b", "#8b631f",
                "#3e659a", "#7e538f", "#276f79", "#d1d2d4",
                "#6b6e75", "#b44d57", "#4d7851", "#8f6724",
                "#4c6fa3", "#895f99", "#327880", "#e7e7e8",
            ]
        ),
        .make(
            "Harness Glacier",
            bg: "#edf4fa", fg: "#283b4b", cursor: "#286c9b",
            selectionBackground: "#cddfea",
            palette: [
                "#283b4b", "#a23f55", "#38704f", "#835f21",
                "#28659e", "#755391", "#1f6d7b", "#c0d1df",
                "#5a7082", "#ad4b60", "#427959", "#8c672a",
                "#3571a8", "#805f9c", "#2a7782", "#dde8f0",
            ]
        ),
        .make(
            "Harness Seafoam",
            bg: "#edf5f0", fg: "#2b4039", cursor: "#2c7565",
            selectionBackground: "#cce2d7",
            palette: [
                "#2b4039", "#a03f4b", "#386d42", "#805f22",
                "#3b6295", "#7a518b", "#246c67", "#c3d4ca",
                "#5c7366", "#ad4c56", "#46784c", "#8a682b",
                "#4870a0", "#875d97", "#31786f", "#dfebe3",
            ]
        ),
        .make(
            "Harness Lavender",
            bg: "#f3eff9", fg: "#3c334b", cursor: "#7953a2",
            selectionBackground: "#ded4ed",
            palette: [
                "#3c334b", "#a33d59", "#45683e", "#835e25",
                "#465f9e", "#7953a2", "#306c77", "#d0c6df",
                "#756783", "#ae4b65", "#507449", "#8b652d",
                "#516ba8", "#825aaa", "#3a747f", "#e8e0f1",
            ]
        ),
        .make(
            "Harness Rose Quartz",
            bg: "#faf0f0", fg: "#49343b", cursor: "#97526c",
            selectionBackground: "#ecd5dd",
            palette: [
                "#49343b", "#a33e4c", "#4c6b46", "#865f28",
                "#486698", "#87538e", "#316d70", "#dcc8ce",
                "#7d676f", "#af4b59", "#57754e", "#8c662e",
                "#506d9f", "#8f5a94", "#3b7679", "#f0e1e4",
            ]
        ),
        .make(
            "Harness Sandstone",
            bg: "#f2e9de", fg: "#45392e", cursor: "#8a623d",
            selectionBackground: "#e0cfb9",
            palette: [
                "#45392e", "#9d4035", "#506338", "#805b21",
                "#3e6089", "#795080", "#326961", "#cfc1ad",
                "#736654", "#a84b40", "#5c6e42", "#856228",
                "#496a93", "#835a89", "#3b7269", "#e7dac8",
            ]
        ),
    ]
}
