# App icon

The layered Icon Composer source is `Clio/Resources/AppIcon.icon`. The matching
PNG asset catalog provides fallback icon sizes. Preserve both when changing the
artwork.

With Icon Composer installed, regenerate fallbacks using:

```sh
bash scripts/update-app-icon.sh
```

Rebuild the application to include the updated resources. Existing downloadable
releases are immutable and are not changed by editing the icon source.
