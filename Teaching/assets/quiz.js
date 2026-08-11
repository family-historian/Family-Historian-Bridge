// Shared quiz widget behaviour for FH MCP Bridge lessons.
// Markup contract:
// <div class="quiz" data-correct="1">          <!-- 0-indexed correct choice -->
//   <div class="q">Question text?</div>
//   <div class="choices">
//     <button class="choice">Answer A</button>
//     <button class="choice">Answer B</button>
//     ...
//   </div>
//   <div class="feedback"></div>
// </div>
document.addEventListener("DOMContentLoaded", () => {
  document.querySelectorAll(".quiz").forEach((quiz) => {
    const correctIndex = parseInt(quiz.dataset.correct, 10);
    const choices = Array.from(quiz.querySelectorAll(".choice"));
    const feedback = quiz.querySelector(".feedback");
    let answered = false;

    choices.forEach((btn, i) => {
      btn.addEventListener("click", () => {
        if (answered) return;
        answered = true;
        choices.forEach((b, j) => {
          b.disabled = true;
          if (j === correctIndex) b.classList.add("correct");
          else if (j === i) b.classList.add("incorrect");
        });
        if (feedback) {
          feedback.textContent =
            i === correctIndex
              ? (quiz.dataset.right || "Correct.")
              : (quiz.dataset.wrong || "Not quite — see the correct answer highlighted above.");
        }
      });
    });
  });
});
