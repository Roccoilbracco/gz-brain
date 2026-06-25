-- Progetti remoti: la tab Code apre claude su un host via SSH invece del claude locale.
-- Se ssh_host è valorizzato, il progetto è remoto; ssh_path è la cartella di lavoro remota (NULL = home).
ALTER TABLE public.projects
  ADD COLUMN IF NOT EXISTS ssh_host text,
  ADD COLUMN IF NOT EXISTS ssh_path text;

COMMENT ON COLUMN public.projects.ssh_host IS 'Se valorizzato, progetto remoto: la tab Code apre ssh <ssh_host> invece del claude locale';
COMMENT ON COLUMN public.projects.ssh_path IS 'Cartella di lavoro remota dove avviare claude (default: home remota)';

-- Primo progetto remoto: NVIDIA DGX Spark (accesso via alias ssh "dgx-spark" su Tailscale).
INSERT INTO public.projects (slug, name, description, status, hue, ssh_host, ssh_path, sort_order)
VALUES (
  'dgx-spark',
  'DGX Spark',
  'NVIDIA DGX Spark — Claude Code remoto via SSH (Tailscale)',
  'live',
  84,
  'dgx-spark',
  NULL,
  (SELECT COALESCE(MAX(sort_order),0)+1 FROM public.projects)
)
ON CONFLICT (slug) DO UPDATE SET
  name=EXCLUDED.name, description=EXCLUDED.description, status=EXCLUDED.status,
  hue=EXCLUDED.hue, ssh_host=EXCLUDED.ssh_host, ssh_path=EXCLUDED.ssh_path;
