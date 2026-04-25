# Exported metrics

This fork now exports only Space Age metrics. Everything else was removed on purpose.

### Rocket cargo

| Name                            | Labels                     | Description                                       |
|---------------------------------|----------------------------|---------------------------------------------------|
| `factorio_items_launched_total` | force<br/>name | How many of each item has been sent to space |

### Space platforms

| Name                              | Labels                       | Description                                  |
|-----------------------------------|------------------------------|----------------------------------------------|
| `factorio_platform_count`         | force                        | Number of space platforms owned by the force |
| `factorio_platform_state`         | force<br/>platform<br/>state | 1 for the platform's current state           |
| `factorio_platform_weight`        | force<br/>platform           | Total platform weight                        |
| `factorio_platform_speed`         | force<br/>platform           | Current platform speed                       |
| `factorio_platform_distance`      | force<br/>platform           | Current progress along the active route      |
| `factorio_platform_damaged_tiles` | force<br/>platform           | Number of damaged tiles on the platform      |
