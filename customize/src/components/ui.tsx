import { cva, type VariantProps } from "class-variance-authority";
import { forwardRef, type ButtonHTMLAttributes, type HTMLAttributes, type InputHTMLAttributes, type SelectHTMLAttributes, type TextareaHTMLAttributes } from "react";
import { cn } from "@/lib/utils";

/* ── Button ── */
const button = cva(
  "inline-flex items-center justify-center gap-2 rounded-md text-[13px] font-bold uppercase tracking-[0.02em] transition-colors disabled:cursor-not-allowed",
  {
    variants: {
      variant: {
        primary: "bg-primary text-primary-foreground shadow-[0_1px_4px_rgba(0,0,0,0.22)] hover:bg-primary-hover disabled:bg-muted disabled:text-muted-foreground disabled:shadow-none",
        ghost: "border border-border bg-muted text-foreground hover:bg-muted-hover",
        danger: "border border-danger-border bg-surface text-danger hover:bg-danger-tint",
      },
      size: { md: "h-[42px] px-4", sm: "h-[34px] px-3 text-[12px]" },
    },
    defaultVariants: { variant: "primary", size: "md" },
  }
);
export interface ButtonProps
  extends ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof button> {}
export const Button = forwardRef<HTMLButtonElement, ButtonProps>(
  ({ className, variant, size, ...props }, ref) => (
    <button ref={ref} className={cn(button({ variant, size }), className)} {...props} />
  )
);
Button.displayName = "Button";

/* ── Input ── */
export const Input = forwardRef<HTMLInputElement, InputHTMLAttributes<HTMLInputElement>>(
  ({ className, ...props }, ref) => (
    <input
      ref={ref}
      className={cn(
        "h-[42px] w-full rounded-md border border-border bg-surface px-3 text-sm text-foreground outline-none transition focus:border-primary focus:shadow-[0_0_0_3px_rgba(37,99,235,0.20)]",
        className
      )}
      {...props}
    />
  )
);
Input.displayName = "Input";

/* ── Select ── */
export const Select = forwardRef<HTMLSelectElement, SelectHTMLAttributes<HTMLSelectElement>>(
  ({ className, ...props }, ref) => (
    <select
      ref={ref}
      className={cn(
        "h-[42px] w-full rounded-md border border-border bg-surface px-3 text-sm text-foreground outline-none transition focus:border-primary focus:shadow-[0_0_0_3px_rgba(37,99,235,0.20)]",
        className
      )}
      {...props}
    />
  )
);
Select.displayName = "Select";

/* ── Textarea ── */
export const Textarea = forwardRef<HTMLTextAreaElement, TextareaHTMLAttributes<HTMLTextAreaElement>>(
  ({ className, ...props }, ref) => (
    <textarea
      ref={ref}
      className={cn(
        "min-h-[88px] w-full rounded-md border border-border bg-surface p-3 text-sm text-foreground outline-none transition focus:border-primary focus:shadow-[0_0_0_3px_rgba(37,99,235,0.20)]",
        className
      )}
      {...props}
    />
  )
);
Textarea.displayName = "Textarea";

/* ── Card ── */
export function Card({ className, ...props }: HTMLAttributes<HTMLDivElement>) {
  return <div className={cn("rounded-lg border border-border bg-surface", className)} {...props} />;
}

/* ── Pill ── */
export function Pill({ active }: { active: boolean }) {
  return (
    <span
      className={cn(
        "inline-flex items-center rounded-full px-[11px] py-[3px] text-xs font-bold",
        active ? "bg-success-tint text-success" : "bg-danger-tint text-danger"
      )}
    >
      {active ? "Active" : "Inactive"}
    </span>
  );
}
