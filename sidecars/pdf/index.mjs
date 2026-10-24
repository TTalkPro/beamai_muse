// PDF port program for muse_pdf (designs/04-integrations.md §2).
//
// Reads {packet,4} frames (4-byte big-endian length + UTF-8 JSON) from stdin
// and answers each with one frame on stdout, strictly one request at a time:
//
//   {"op":"inspect","pdf":<base64>}               -> {"ok":{"pageCount":N,"fields":[...]}}
//   {"op":"fill","pdf":<base64>,"values":{...}}   -> {"ok":{"pdf":<base64>}}
//   {"op":"sample"}                               -> {"ok":{"pdf":<base64>}}
//   any failure                                   -> {"error":"PdfError","message":...}
//
// The PDF logic is a plain-JS port of OpenMuse packages/integrations/src/pdf.ts
// (designs/ref/openmuse-integrations-spec.md §5.3-§5.5); error messages are
// identical. A bad request never terminates the process; EOF on stdin does.
import pdfLib from "pdf-lib";

const {
  PDFArray,
  PDFCheckBox,
  PDFDict,
  PDFDocument,
  PDFDropdown,
  PDFHexString,
  PDFName,
  PDFOptionList,
  PDFRadioGroup,
  PDFString,
  PDFTextField,
  rgb,
  StandardFonts,
} = pdfLib;

const MAX_PDF_BYTES = 10 * 1024 * 1024;
const MAX_PDF_PAGES = 500;

// stdout carries frames only; keep any library logging on stderr.
console.log = console.error;
console.info = console.error;

class PdfError extends Error {
  constructor(message) {
    super(message);
    this.name = "PdfError";
    this.status = 422;
  }
}

async function pdfOperation(operation, fallback) {
  try {
    return await operation();
  } catch (error) {
    if (error instanceof PdfError) throw error;
    throw new PdfError(fallback);
  }
}

async function loadPdf(bytes) {
  if (
    !bytes.length ||
    bytes.length > MAX_PDF_BYTES ||
    Buffer.from(bytes.subarray(0, 1024)).indexOf("%PDF-") < 0
  ) {
    throw new PdfError("Invalid PDF: expected nonempty PDF bytes up to 10 MiB");
  }
  try {
    const doc = await PDFDocument.load(new Uint8Array(bytes), {
      ignoreEncryption: false,
      throwOnInvalidObject: true,
      updateMetadata: false,
    });
    if (doc.isEncrypted) throw new PdfError("Encrypted PDFs are not supported");
    if (doc.catalog.lookupMaybe(PDFName.of("AcroForm"), PDFDict)?.has(PDFName.of("XFA"))) {
      throw new PdfError("Unsupported XFA PDF form");
    }
    if (doc.getPageCount() < 1 || doc.getPageCount() > MAX_PDF_PAGES)
      throw new PdfError("PDF must contain between 1 and 500 pages");
    return doc;
  } catch (error) {
    if (error instanceof PdfError) throw error;
    if (error instanceof Error && /encrypt/i.test(error.message))
      throw new PdfError("Encrypted PDFs are not supported");
    throw new PdfError("Invalid or malformed PDF");
  }
}

function inspectField(field) {
  const name = field.getName();
  if (field instanceof PDFTextField) {
    const value = field.acroField.dict.lookup(PDFName.of("V"));
    if (value !== undefined && !(value instanceof PDFString) && !(value instanceof PDFHexString)) {
      throw new PdfError("Cannot inspect PDF: a text field contains a malformed value");
    }
    return { name, value: field.getText() ?? "", type: "text" };
  }
  if (field instanceof PDFCheckBox)
    return { name, value: String(field.isChecked()), type: "checkbox" };
  const value =
    field instanceof PDFDropdown || field instanceof PDFOptionList
      ? field.getSelected().join(", ")
      : field instanceof PDFRadioGroup
        ? (field.getSelected() ?? "")
        : "";
  return { name, value, type: "unsupported" };
}

async function inspectPdf(bytes) {
  return pdfOperation(async () => {
    const doc = await loadPdf(bytes);
    return { pageCount: doc.getPageCount(), fields: doc.getForm().getFields().map(inspectField) };
  }, "Cannot inspect PDF: the document contains malformed or unsupported form fields");
}

/** Strip action entry points in the new output; never execute PDF scripts. */
function removeActions(doc) {
  const visited = new Set();
  const visit = (object) => {
    if (visited.has(object)) return;
    visited.add(object);
    if (object instanceof PDFDict) {
      for (const key of ["OpenAction", "AA", "A", "JS", "JavaScript"])
        object.delete(PDFName.of(key));
      for (const value of object.values()) visit(value);
    } else if (object instanceof PDFArray) {
      for (const value of object.asArray()) visit(value);
    }
  };
  for (const [, object] of doc.context.enumerateIndirectObjects()) visit(object);
}

async function fillPdf(bytes, values) {
  return pdfOperation(async () => {
    const doc = await loadPdf(bytes);
    const form = doc.getForm();
    const fields = new Map(form.getFields().map((field) => [field.getName(), field]));
    for (const [name, value] of Object.entries(values)) {
      const field = fields.get(name);
      if (!field) throw new PdfError(`Unknown PDF field: ${name}`);
      if (field instanceof PDFTextField) {
        if (typeof value !== "string")
          throw new PdfError(`PDF text field requires a string: ${name}`);
        if (value.length > 10000) throw new PdfError(`PDF text field value is too long: ${name}`);
        field.setText(value);
      } else if (field instanceof PDFCheckBox) {
        if (typeof value !== "boolean")
          throw new PdfError(`PDF checkbox requires a boolean: ${name}`);
        if (value) field.check();
        else field.uncheck();
      } else {
        throw new PdfError(`Unsupported PDF field: ${name}`);
      }
    }
    removeActions(doc);
    try {
      form.updateFieldAppearances(await doc.embedFont(StandardFonts.Helvetica));
      return await doc.save();
    } catch {
      throw new PdfError(
        "Could not render PDF field values; use characters supported by this form's font or choose a compatible PDF form",
      );
    }
  }, "Could not fill PDF: the document contains malformed or unsupported form fields");
}

/** Original synthetic fixture. Personal details remain blank until explicitly supplied. */
async function createSamplePdf() {
  return pdfOperation(async () => {
    const doc = await PDFDocument.create();
    doc.setTitle("Community visit - permission form");
    doc.setAuthor("OpenMuse");
    const regular = await doc.embedFont(StandardFonts.Helvetica);
    const bold = await doc.embedFont(StandardFonts.HelveticaBold);
    const ink = rgb(0.12, 0.19, 0.2);
    const teal = rgb(0.18, 0.4, 0.4);
    const form = doc.getForm();
    const pages = [doc.addPage([612, 792]), doc.addPage([612, 792])];
    for (const [index, page] of pages.entries()) {
      page.drawRectangle({ x: 0, y: 682, width: 612, height: 110, color: rgb(0.9, 0.95, 0.93) });
      page.drawText("OPENMUSE / COMMUNITY VISIT", { x: 48, y: 750, size: 10, font: bold, color: teal });
      page.drawText(index === 0 ? "Community visit" : "Permission & contacts", {
        x: 48,
        y: 710,
        size: 28,
        font: bold,
        color: ink,
      });
      page.drawLine({
        start: { x: 48, y: 55 },
        end: { x: 564, y: 55 },
        color: rgb(0.8, 0.85, 0.83),
        thickness: 1,
      });
      page.drawText("EXAMPLE FORM - no real participant or organization", {
        x: 48,
        y: 35,
        size: 9,
        font: regular,
        color: teal,
      });
      page.drawText(`${index + 1} / 2`, { x: 535, y: 35, size: 9, font: regular, color: teal });
    }
    const [first, second] = pages;
    first.drawText("A day of discovery at the community museum", {
      x: 48,
      y: 640,
      size: 16,
      font: bold,
      color: ink,
    });
    const details = [
      "Please complete both pages of this permission form.",
      "The visit, organization, and schedule below are fictional.",
      "Schedule: Saturday, October 10, 2026 / 10:00-14:00",
      "Activities: guided exhibits, a sketching workshop, and a lunch break.",
      "Bring: a packed lunch, water, and comfortable shoes.",
    ];
    details.forEach((line, index) => {
      first.drawText(line, { x: 48, y: 606 - index * 25, size: 11, font: regular, color: ink });
    });
    const addText = (page, name, label, y, multiline = false) => {
      page.drawText(label, { x: 48, y: y + (multiline ? 72 : 40), size: 11, font: bold, color: ink });
      const field = form.createTextField(name);
      if (multiline) field.enableMultiline();
      field.addToPage(page, {
        x: 48,
        y,
        width: 516,
        height: multiline ? 62 : 30,
        borderWidth: 1,
        borderColor: rgb(0.65, 0.75, 0.71),
        backgroundColor: rgb(1, 1, 1),
        font: regular,
      });
      field.setFontSize(12);
    };
    addText(first, "participant_name", "Participant name", 395);
    addText(first, "guardian_name", "Parent or guardian name (if applicable)", 305);
    first.drawText("Continue to page 2 for emergency contacts and permission.", {
      x: 48,
      y: 210,
      size: 11,
      font: regular,
      color: teal,
    });
    addText(second, "emergency_contact", "Emergency contact name", 580);
    addText(second, "emergency_phone", "Emergency contact phone", 490);
    addText(second, "additional_notes", "Additional notes (optional)", 375, true);
    const permission = form.createCheckBox("permission_granted");
    permission.addToPage(second, { x: 48, y: 290, width: 18, height: 18, borderWidth: 1, borderColor: teal });
    second.drawText("I give permission for the participant to attend the community visit.", {
      x: 78,
      y: 295,
      size: 11,
      font: regular,
      color: ink,
    });
    second.drawText("This checkbox records permission; it is not a digital signature.", {
      x: 48,
      y: 235,
      size: 10,
      font: regular,
      color: teal,
    });
    form.updateFieldAppearances(regular);
    return doc.save();
  }, "Could not create the sample PDF");
}

// Protocol

const isObject = (value) => typeof value === "object" && value !== null && !Array.isArray(value);

function pdfBytes(request) {
  if (typeof request.pdf !== "string") throw new PdfError("Invalid request: pdf must be base64");
  return Buffer.from(request.pdf, "base64");
}

async function handle(frame) {
  let request;
  try {
    request = JSON.parse(frame.toString("utf8"));
  } catch {
    throw new PdfError("Invalid request: malformed JSON");
  }
  if (!isObject(request)) throw new PdfError("Invalid request: expected an object");
  switch (request.op) {
    case "inspect":
      return inspectPdf(pdfBytes(request));
    case "fill": {
      const bytes = pdfBytes(request);
      if (!isObject(request.values)) throw new PdfError("Invalid request: values must be an object");
      const filled = await fillPdf(bytes, request.values);
      return { pdf: Buffer.from(filled).toString("base64") };
    }
    case "sample":
      return { pdf: Buffer.from(await createSamplePdf()).toString("base64") };
    default:
      throw new PdfError("Invalid request: unknown op");
  }
}

function reply(message) {
  const body = Buffer.from(JSON.stringify(message), "utf8");
  const header = Buffer.alloc(4);
  header.writeUInt32BE(body.length, 0);
  process.stdout.write(Buffer.concat([header, body]));
}

async function serve(frame) {
  try {
    reply({ ok: await handle(frame) });
  } catch (error) {
    const message = error instanceof PdfError ? error.message : "PDF operation failed";
    reply({ error: "PdfError", message });
  }
}

let pending = Buffer.alloc(0);
let queue = Promise.resolve();

process.stdin.on("data", (chunk) => {
  pending = pending.length ? Buffer.concat([pending, chunk]) : chunk;
  while (pending.length >= 4) {
    const size = pending.readUInt32BE(0);
    if (pending.length < 4 + size) break;
    const frame = pending.subarray(4, 4 + size);
    pending = pending.subarray(4 + size);
    queue = queue.then(() => serve(frame));
  }
});
process.stdin.on("end", () => {
  queue.then(() => process.exit(0));
});
