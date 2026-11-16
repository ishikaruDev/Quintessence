Quintessence Adventor (QuintessenceAdventor.ttf)
================================================

The font of Quintessence's text boxes: the template editor, the macro
text, the input fields and the guide's examples.

It is a modified version of TeX Gyre Adventor 2.501, by B. Jackowski,
J. M. Nowacki et al., on behalf of the TeX Users Groups (GUST e-foundry),
itself based on URW's version of Avant Garde Gothic. It is distributed
under the GUST Font License (GUST-FONT-LICENSE.txt), an instance of the
LaTeX Project Public License 1.3c (LPPL-1.3c.txt).

Changes from the original, made by tools/build_font.py in the Quintessence
sources:
  - the CFF (PostScript) outlines converted to TrueType (quadratic)
    outlines, since the World of Warcraft 3.3.5a client reads TrueType;
  - reduced to Basic Latin, Latin-1, Latin Extended-A, general
    punctuation, the euro sign and the trade mark sign;
  - thickened to a Medium weight: every outline grown by 16 units (of
    1000) on each side, and each letter's width by 32;
  - renamed "Quintessence Adventor Medium" (file QuintessenceAdventor.ttf),
    as the license requests of modified fonts.

The original, unmodified TeX Gyre Adventor is available from
  https://www.gust.org.pl/projects/e-foundry/tex-gyre
  https://ctan.org/pkg/tex-gyre-adventor

The authors of TeX Gyre Adventor do not support this modified version;
report problems with it to Quintessence, not to them.
