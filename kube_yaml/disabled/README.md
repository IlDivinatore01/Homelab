# Disabled pods

Pod YAMLs kept on disk for documentation / future re-enable, but not part of
the active boot set. They are NOT referenced by any quadlet under
`quadlets/` and not listed in the `SERVICES` / `PODS` arrays in
`manage.sh`.

| Pod        | Why disabled                          | Data still at        |
|------------|---------------------------------------|----------------------|
| `actual`   | Budget app — replaced by Firefly III. | `data/actual/`       |
| `metabase` | Analytics — no longer used.           | `data/metabase/`     |

## To re-enable

1. Move the YAML back: `git mv kube_yaml/disabled/<svc>.pod.yaml kube_yaml/`
2. Add the pod to the `PODS` map and `SERVICES` array in `manage.sh`.
3. Create a `quadlets/<svc>.kube` (copy a similar service as a template and
   splice it into the `After=` chain — see `quadlets/README.md`).
4. `./manage.sh` → verify quadlets, then start the service.
