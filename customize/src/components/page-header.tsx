import { Plus } from "lucide-react";
import { Button } from "@/components/ui";
import { useEnterpriseStore } from "@/stores/enterprise-store";

export function PageHeader({
  title,
  subtitle,
  actionLabel,
  onAction,
}: {
  title: string;
  subtitle: string;
  actionLabel?: string;
  onAction?: () => void;
}) {
  const enterprise = useEnterpriseStore((s) => s.selected);
  return (
    <div className="mb-[22px] flex items-end justify-between">
      <div>
        <p className="mb-0.5 text-[11px] font-bold uppercase tracking-[0.1em] text-primary">{enterprise?.name}</p>
        <h2 className="text-[26px] font-black text-foreground">{title}</h2>
        <p className="mt-1 text-sm text-muted-foreground">{subtitle}</p>
      </div>
      {actionLabel && onAction ? (
        <Button onClick={onAction}>
          <Plus className="h-[15px] w-[15px]" />
          {actionLabel}
        </Button>
      ) : null}
    </div>
  );
}
