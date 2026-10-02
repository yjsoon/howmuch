import type { ReactElement } from "react";
import halationLight from "../../../../assets/icon/halation-light.svg";

type HalationSize = "lockup" | "hero";

const PX: Record<HalationSize, number> = {
  lockup: 40,
  hero: 96,
};

export function HalationMark({ size }: { size: HalationSize }): ReactElement {
  const px = PX[size];
  return (
    <img
      className={`halation-mark halation-mark--${size}`}
      src={halationLight}
      alt=""
      aria-hidden="true"
      width={px}
      height={px}
      draggable={false}
    />
  );
}

export function BrandLockup({
  tagline,
  href,
}: {
  tagline: string;
  href?: string;
}): ReactElement {
  const inner = (
    <>
      <HalationMark size="lockup" />
      <span>
        <strong>Halation</strong>
        <small>{tagline}</small>
      </span>
    </>
  );
  if (href) {
    return (
      <a className="brand-lockup" href={href}>
        {inner}
      </a>
    );
  }
  return <div className="brand-lockup">{inner}</div>;
}
