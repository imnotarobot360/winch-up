// @vitest-environment happy-dom
import { render, screen } from "@testing-library/react";
import { describe, expect, it } from "vitest";

import { Checkbox, ChoiceList, Field, TextArea, TextInput } from "./primitives";

/**
 * Whether a label is actually attached to its control.
 *
 * This is not a styling detail. `getByLabelText` fails in precisely the way a screen reader
 * fails — an end-to-end test could not find a sign-in field by its label, and that turned out to
 * be 36 of 61 call sites rendering `<label htmlFor={undefined}>`. These tests exist so the
 * association is a property of the component rather than something every call site has to
 * remember.
 */
describe("Field", () => {
  describe("a single labelable control", () => {
    it("connects the label to a text input", () => {
      render(
        <Field label="Home area">
          <TextInput defaultValue="" />
        </Field>,
      );
      // Would throw if the label were not associated.
      expect(screen.getByLabelText("Home area")).toBeTruthy();
    });

    it("connects the label to a textarea", () => {
      render(
        <Field label="Anything else">
          <TextArea defaultValue="" />
        </Field>,
      );
      expect(screen.getByLabelText("Anything else")).toBeTruthy();
    });

    it("connects the label to a bare select", () => {
      render(
        <Field label="Type">
          <select defaultValue="truck">
            <option value="truck">Truck</option>
          </select>
        </Field>,
      );
      expect(screen.getByLabelText("Type")).toBeTruthy();
    });

    it("leaves an id the caller supplied alone", () => {
      render(
        <Field label="Year" htmlFor="year-field">
          <TextInput id="year-field" defaultValue="" />
        </Field>,
      );
      expect(screen.getByLabelText("Year").getAttribute("id")).toBe("year-field");
    });

    it("gives two fields on the same page distinct ids", () => {
      render(
        <>
          <Field label="Make">
            <TextInput defaultValue="" />
          </Field>
          <Field label="Model">
            <TextInput defaultValue="" />
          </Field>
        </>,
      );
      const make = screen.getByLabelText("Make").getAttribute("id");
      const model = screen.getByLabelText("Model").getAttribute("id");
      expect(make).toBeTruthy();
      expect(make).not.toBe(model);
    });
  });

  describe("a group of controls", () => {
    it("announces a checkbox list by the label above it", () => {
      render(
        <Field label="What you can bring">
          <div>
            <Checkbox id="a" checked={false} onChange={() => {}}>
              Winch
            </Checkbox>
            <Checkbox id="b" checked={false} onChange={() => {}}>
              Traction boards
            </Checkbox>
          </div>
        </Field>,
      );

      // The failure this replaces: thirteen checkboxes read out with no indication of what they
      // belong to.
      const group = screen.getByRole("group", { name: "What you can bring" });
      expect(group).toBeTruthy();
      expect(group.querySelectorAll("input[type=checkbox]")).toHaveLength(2);
    });

    it("does not put a label's for at a div, which would be invalid", () => {
      const { container } = render(
        <Field label="How stuck">
          <div>
            <Checkbox id="c" checked={false} onChange={() => {}}>
              Hubs
            </Checkbox>
          </div>
        </Field>,
      );
      const label = container.querySelector("label");
      expect(label?.getAttribute("for")).toBeNull();
    });

    it("leaves a component that names itself alone", () => {
      render(
        <Field label="Drivetrain">
          <ChoiceList
            name="Drivetrain"
            value="4wd"
            onChange={() => {}}
            options={[
              { value: "4wd", label: "4WD" },
              { value: "2wd", label: "2WD" },
            ]}
          />
        </Field>,
      );
      // ChoiceList already sets role=radiogroup and aria-label, so Field must not fight it.
      expect(screen.getByRole("radiogroup", { name: "Drivetrain" })).toBeTruthy();
    });
  });

  describe("the rest of the field", () => {
    it("shows a hint without stealing the accessible name", () => {
      render(
        <Field label="Tire size" hint="For example 35x12.50R17.">
          <TextInput defaultValue="" />
        </Field>,
      );
      expect(screen.getByLabelText("Tire size")).toBeTruthy();
      expect(screen.getByText("For example 35x12.50R17.")).toBeTruthy();
    });

    it("announces an error immediately rather than silently", () => {
      render(
        <Field label="Email" error="That doesn't look right.">
          <TextInput defaultValue="" />
        </Field>,
      );
      expect(screen.getByRole("alert").textContent).toBe("That doesn't look right.");
    });
  });
});
