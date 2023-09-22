;;; org-tree.el --- Navigate Org headings via tree outline           -*- lexical-binding: t; -*-

;; Copyright (C) 2023  Grant Rosson

;; Author: Grant Rosson <https://github.com/localauthor>
;; Created: September 7, 2023
;; License: GPL-3.0-or-later
;; Version: 0.3
;; Homepage: https://github.com/localauthor/org-tree
;; Package-Requires: ((emacs "27.2"))

;; This program is free software; you can redistribute it and/or modify it
;; under the terms of the GNU General Public License as published by the Free
;; Software Foundation, either version 3 of the License, or (at your option)
;; any later version.

;; This program is distributed in the hope that it will be useful, but
;; WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY
;; or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License
;; for more details.

;; You should have received a copy of the GNU General Public License along
;; with this program. If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Navigate Org headings via tree outline in a side window.

;; Inspired by, modeled on `org-sidebar-tree' from org-sidebar by @alphapapa
;; and `embark-live' from Embark by @oantolin.

;; TODO check for movement to new subheading
;; using post-command-hook, or idle-timer?
;; pseudo:
;; get current org-heading
;; when (not eq last current)
;; then move cursor in tree-window

;; FIX: movement of cursor in tree window presumes non-identical headings,
;; since it uses search-forward;; how to differentiate headings absolutely?

;; affected functions: org-tree; org-tree-live-update; org-tree-refresh-line;
;; org-tree-next and previous

;; maybe:
;; count the number of headings
;; and go to that one

;; Ok, that works, but it's slower, so with live-update, typing is laggy

;; maybe: live-update can be on a timer (2 or 3 seconds) instead of on after-change-functions??

;;; Code:

(require 'org)

(defvar org-tree-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "<return>") #'push-button)
    (define-key map (kbd "<mouse-1>") #'push-button)
    (define-key map (kbd "n") #'org-tree-next-heading)
    (define-key map (kbd "p") #'org-tree-previous-heading)
    (make-composed-keymap map special-mode-map))
  "Keymap for `org-tree-mode'.")

(define-derived-mode org-tree-mode tabulated-list-mode "Org-Tree"
  "Mode for `org-tree'.

\\{org-tree-mode-map}"
  (hl-line-mode)
  (setq-local cursor-type 'bar)
  (setq tabulated-list-format [("Tree" 100)])
  (set-window-fringes (selected-window) 1)
  (setq fringe-indicator-alist
        '((truncation nil nil))))

(define-button-type 'org-tree
  'action 'org-tree-jump
  'help-echo nil)

(defcustom org-tree-narrow-on-jump t
  "When non-nil, source buffer is narrowed to subtree."
  :group 'org-tree
  :type 'boolean)

;;;###autoload
(defun org-tree ()
  "Create Org-Tree buffer."
  (interactive)
  (when (org-tree-buffer-p)
    (error "Don't tree a tree"))
  (unless (derived-mode-p 'org-mode)
    (error "Not an org buffer"))
  (let* ((tree-name (format "<tree>%s" (buffer-name)))
         (tree-buffer (get-buffer tree-name))
         (heading (org-tree-heading-number)))
    (unless (buffer-live-p tree-buffer)
      (setq tree-buffer (generate-new-buffer tree-name))
      (save-restriction
        (widen)
        (jit-lock-mode 1)
        (jit-lock-fontify-now))
      (let* ((headings (org-tree--headings))
             (tree-mode-line (format "Org-Tree - %s"
                                     (file-name-nondirectory buffer-file-name))))
        (add-hook 'after-change-functions #'org-tree-live-update nil t)
        (with-current-buffer tree-buffer
          (org-tree-mode)
          (setq tabulated-list-entries headings)
          (tabulated-list-print t t)
          (setq mode-line-format tree-mode-line))))
    (pop-to-buffer tree-buffer)
    (set-window-fringes (get-buffer-window tree-buffer) 1 1)
    ;; is this necessary?
    (goto-char (point-min))
    ;; is this 'when' necessary?
    (when heading
      (org-tree-go-to-heading heading))
    (beginning-of-line)
    (hl-line-highlight)))

(defun org-tree--headings ()
  "Return a list of outline headings."
  (interactive)
  (let* ((heading-regexp (concat "^\\(?:"
                                 org-outline-regexp
                                 "\\)"))
         (buffer (current-buffer))
         headings)
    (save-restriction
      (widen)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward heading-regexp nil t)
          (push (list
                 (org-get-heading t)
                 (vector (cons (buffer-substring
                                (line-beginning-position)
                                (line-end-position))
                               `(type org-tree
                                      buffer ,buffer
                                      pos ,(point-marker)
                                      keymap org-tree-mode-map))))
                headings)
          (goto-char (1+ (line-end-position))))))
    (unless headings
      (user-error "No headings"))
    (nreverse headings)))

(defun org-tree-live-update (_1 _2 _3)
  "Update headings."
  (let ((tree-buffer (get-buffer
                      (format "<tree>%s"
                              (buffer-name))))
        (heading (org-tree-heading-number))
        timer)
    (if tree-buffer
        (unless timer
          (setq timer
                (run-with-idle-timer
                 0.05 nil
                 (lambda ()
                   (let ((headings (org-tree--headings)))
                     (with-current-buffer tree-buffer
                       (setq tabulated-list-entries headings)
                       (tabulated-list-print t t)
                       ;;is this necessary?
                       (goto-char (point-min))
                       (org-tree-go-to-heading heading)
                       (beginning-of-line)
                       (hl-line-highlight)
                       )
                     (setq timer nil))))))
      (remove-hook 'after-change-functions
                   #'org-tree-live-update t))))

(defun org-tree-refresh-line (&optional n)
  "Move org-tree cursor to Nth heading.
If called from tree-buffer, use let-bound N from base-buffer."
  (interactive)
  (let* ((tree-buffer (or (get-buffer
                           (format "<tree>%s"
                                   (buffer-name)))
                          ""))
         (tree-window (get-buffer-window tree-buffer))
         (n (or n (org-tree-heading-count))))
    (when tree-window
      (with-selected-window tree-window
        (when n
          (org-tree-go-to-heading n))
        (beginning-of-line)
        (hl-line-highlight)))))

(defun org-tree-buffer-p (&optional buffer)
  "Is this BUFFER a tree-buffer?"
  (interactive)
  (let ((buffer (or buffer (buffer-name))))
    (string-match "^<tree>.*" buffer)))

(defun org-tree-heading-number ()
  "Return the number of the current heading."
  (let ((count 0)
        (end (point)))
    (save-restriction
      (widen)
      (save-excursion
        (goto-char (point-min))
        (while (and (outline-next-heading)
                    (< (point) end))
          (setq count (1+ count)))))
    count))

(defun org-tree-go-to-heading (n)
  "Go to Nth heading."
  (goto-char (point-min))
  (dotimes (x (1- n))
    (outline-next-heading)))

(defun org-tree-jump (&optional _)
  "Jump to headline."
  (interactive)
  (let ((tree-window (selected-window))
        (buffer (get-text-property (point) 'buffer))
        ;; point isn't accurate; use marker instead?
        (pos (get-text-property (point) 'pos)))
    (unless (buffer-live-p buffer)
      (when (yes-or-no-p
             "Base buffer has been killed. Kill org-tree window?")
        (kill-buffer-and-window))
      (keyboard-quit))
    (pop-to-buffer buffer)
    (widen)
    (org-fold-show-all)
    (org-fold-hide-drawer-all)
    (goto-char pos)
    (beginning-of-line)
    (recenter-top-bottom 'top)
    (when org-tree-narrow-on-jump
      (org-narrow-to-element))
    (when (or (eq this-command 'org-tree-next-heading)
              (eq this-command 'org-tree-previous-heading))
      (select-window tree-window))))

(defun org-tree-next-heading ()
  "Move to next heading."
  (interactive)
  (if (org-tree-buffer-p)
      (progn
        (forward-line 1)
        (push-button nil t))
    (widen)
    (org-next-visible-heading 1)
    (org-tree-refresh-line)
    (if org-tree-narrow-on-jump
        (org-narrow-to-subtree))))

(defun org-tree-previous-heading ()
  "Move to previous heading."
  (interactive)
  (if (org-tree-buffer-p)
      (progn
        (forward-line -1)
        (push-button nil t))
    (widen)
    (org-previous-visible-heading 1)
    (org-tree-refresh-line)
    (when org-tree-narrow-on-jump
      (unless (org-before-first-heading-p)
        (org-narrow-to-subtree)))))

(provide 'org-tree)
;;; org-tree.el ends here
