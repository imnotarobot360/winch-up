import { IconChevronRight } from "@/components/ui/icons";
import { Link } from "@/i18n/navigation";

/**
 * The settings-menu row from screens 11 and 12 of the design reference: icon, label, chevron.
 *
 * Rows in a single bordered group rather than a stack of cards. Six cards with five lines of
 * padding each turns a six-item menu into two screens of scrolling, and a menu is a thing you
 * scan, not read.
 *
 * Every row here is a Link to a route that exists. The reference's Profile menu lists things this
 * product does not have as separate pages -- there is no standalone "My equipment" screen, it is
 * part of the volunteer details form -- so the labels here name where they actually go. A menu
 * item that opens nothing is worse than one fewer menu item.
 */
export type MenuItem = {
  href: string;
  label: string;
  hint?: string;
  icon: React.ReactNode;
};

export function MenuList({ items, className = "" }: { items: MenuItem[]; className?: string }) {
  return (
    <ul className={`divide-y divide-line overflow-hidden rounded-2xl border border-line ${className}`}>
      {items.map((item) => (
        <li key={item.href + item.label}>
          <Link
            href={item.href}
            className="flex items-center gap-4 bg-surface px-4 py-4 hover:bg-surface-sunk"
          >
            <span className="flex size-10 shrink-0 items-center justify-center rounded-field bg-surface-sunk text-brand-text">
              {item.icon}
            </span>

            <span className="min-w-0 flex-1">
              <span className="block text-base font-bold text-ink">{item.label}</span>
              {item.hint ? (
                <span className="mt-0.5 block text-sm text-ink-soft">{item.hint}</span>
              ) : null}
            </span>

            <IconChevronRight size={20} className="shrink-0 text-ink-faint" />
          </Link>
        </li>
      ))}
    </ul>
  );
}
