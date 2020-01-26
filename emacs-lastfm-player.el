;;; emacs-lastfm-player.el --- The minimalistic and stupid emacs music player -*- lexical-binding: t -*-
;; !!!!!!!!!!!!!!!! DON'T FORGET TO MODIFY THE LAST.FM API !!!!!!!!!!!

;; -------------------------------------------------------------------
;; !!!!!!!!!!!!!!!! DON'T FORGET TO MODIFY THE LAST.FM API !!!!!!!!!!!
;; -------------------------------------------------------------------
;; (lastfm--defmethod album.getInfo (artist album)
;;   "Get the metadata and tracklist for an album on Last.fm using the album name."
;;   :no ("track artist name" "track > name" "duration"))

;; (lastfm--defmethod artist.getInfo (artist)
;;   "Get the metadata for an artist. Includes biography, max 300 characters."
;;   :no ("bio summary" "listeners" "playcount" "similar artist name" "tags tag name"))

;; (lastfm--defmethod artist.getTopTracks (artist (limit 10) (page 1))
;;   "Get the top tracks by an artist, ordered by popularity."
;;   :no ("track artist name" "track > name" "playcount" "listeners"))

(require 'lastfm)
(require 's)
(require 'cl-lib)
(require 'mpv)
(require 'ivy-youtube)
(require 'memoize)

;; Modify to (set-buffer-multibyte t) in elquery-read-string for correct displaying of special chars

(setq ivy-youtube-key "AIzaSyCQlbsX0-ftN3SXba2fhYZu-lWfMxSAgJ0")
(setq browse-url-browser-function 'browse-url-generic
      browse-url-generic-program "chromium")
(setq org-confirm-elisp-link-function nil)

(defun youtube-response-id (*qqJson*)
  "Copied from ivy-youtube-wrapper in mpv.el"
  (let ((search-results (cdr (ivy-youtube-tree-assoc 'items *qqJson*))))
    (cdr (ivy-youtube-tree-assoc 'videoId (aref search-results 0)))))

(defun browse-youtube (str)
  (find-youtube-id
   str (lambda (id)
         (browse-url
          (format "https://www.youtube.com/watch?v=%s" id)))))

(defun play-youtube-video (video-id)
  (mpv-start "--no-video"
             (concat "https://www.youtube.com/watch?v="
                     video-id)))

(defun my-as-string (in)
  (cond ((stringp in) in)
        ((and (consp in) (cl-every #'stringp in))
         (cl-reduce #'concat in))
        (t nil)))

(defun find-youtube-id (artist+song callback)
  (let ((youtube-id)
        (query-str (cond ((stringp artist+song) artist+song)
                         ((and (consp artist+song)
                               (cl-every #'stringp artist+song))
                          (cl-reduce #'concat artist+song))
                         (t nil))))
    (when query-str
      (request
       "https://www.googleapis.com/youtube/v3/search"
       :params `(("part" . "snippet")
                 ("q" . ,query-str)
                 ("type" . "video")
                 ("maxResults" . 1)
                 ("key" .  ,ivy-youtube-key))
       :parser 'json-read       
       :success (cl-function
                 (lambda (&key data &allow-other-keys)
                   (funcall callback (youtube-response-id data))))
       :status-code '((400 . (lambda (&rest _) (message "Got 400.")))
                      ;; (200 . (lambda (&rest _) (message "Got 200.")))
                      (418 . (lambda (&rest _) (message "Got 418.")))
                      (403 . (lambda (&rest _)
                               (message "403: Unauthorized. Maybe you need to enable your youtube api key"))))))
    youtube-id))

(memoize #'find-youtube-id)

(defun counsel-similar-artists (artist)
  (interactive "sArtist: ")
  (ivy-read "Select Artist: "
          (lastfm-artist-get-similar artist :limit 30)
          :action (lambda (a)
                    (display-artist (cl-first a)))))

(define-derived-mode player-mode org-mode "Music Player")
(bind-keys :map player-mode-map
           ("C-m" . org-open-at-point)
           ("q"   . kill-current-buffer)
           ("j"   . next-line)
           ("k"   . previous-line)
           ("l"   . forward-char)
           ("h"   . backward-char))

(defmacro with-player-macro (name &rest body)
  (declare (indent defun))
  (let ((b (make-symbol "buffer")))
    `(let ((,b (generate-new-buffer ,name)))
       (with-current-buffer ,b
         (player-mode)
         ,@body)
       (switch-to-buffer ,b)
       (org-previous-visible-heading 1))))

(defmacro local-set-keys (&rest bindings)
  (declare (indent defun))
  `(progn
     ,@(mapcar (lambda (binding)
                 `(local-set-key
                   (kbd ,(car binding))
                   (lambda () (interactive)
                     ,(cdr binding))))
               bindings)))

(defun display-artist (artist)
  (with-player-macro artist
    (let* ((artist-info (lastfm-artist-get-info artist))
           (songs (lastfm-artist-get-top-tracks artist :limit 25))
           (bio-summary (cl-first artist-info))
           (similar-artists (cl-subseq artist-info 3 7))
           (tags (cl-subseq artist-info 8 12)))
      (insert (format "* %s\n\n %s"
                      artist (s-word-wrap 75 bio-summary)))

      (insert "\n\n* Similar artists: \n")
      (dolist (artist similar-artists)
        (insert (format "|[[elisp:(display-artist \"%s\")][%s]]| "
                        artist artist)))
      
      (insert "\n\n* Popular tags: \n")
      (dolist (tag tags)
        (insert (format "|[[elisp:(display-tag \"%s\")][%s]]| "
                        tag tag)))
      
      (insert "\n\n* Top Songs: \n")
      (cl-loop for i from 1
               for song in songs
               do (insert
                   (format "%2s. [[elisp:(browse-youtube \"%s %s\")][%s]]\n"
                           i artist (cadr song) (cadr song))))

      (local-set-keys
        ("p" . (play-songs (make-generator songs nil)))
        ("s" . (counsel-similar-artists artist))))))


(defun display-tag (tag)
  (with-player-macro tag   
    (let ((info (lastfm-tag-get-info tag))
          ;; (songs (lastfm-tag-get-top-tracks tag :limit 15)) ;; Ignore it
          ;; (tag-similar (lastfm-tag-get-similar tag)) ;; Empty response
          (artists (lastfm-tag-get-top-artists tag :limit 15)))
      
      (insert (format "* %s\n\n %s \n"
                      tag (s-word-wrap 75 (car info))))
     
      (insert "\n** Top Artists: \n")
      (cl-loop for i from 1
               for artist in artists
               do (insert
                   (format "%2s. [[elisp:(display-artist \"%s\")][%s]]\n"
                           i (car artist) (car artist))))
      ;; Top songs for tags are usually just songs for 2, maximum 3 artists and
      ;; are usually bullshit and non-relevant for that tag. Skip it.
      )))

(defun choose-from-user-loved-songs ()
  (interactive)
  (choose-song (lastfm-user-get-loved-tracks :limit 500)))

(defun choose-song (songs)
  (ivy-read "Play song: "
            (mapcar (lambda (song)
                      (format "%s - %s" (car song) (cadr song)))
                    songs)
            :action #'browse-youtube))

(defun display-user-loved-songs (page)
  (with-player-macro "loved-songs"        
    (let* ((per-page 50)
           (songs (lastfm-user-get-loved-tracks :limit per-page :page page)))
      (insert (format "** Loved Songs (Page %s): \n" page))
      (cl-loop for i from (+ 1 (* (1- page) per-page))
               for entry in songs
               for artist = (car entry)
               for song = (cadr entry)
               do (insert
                   (format "%3s. [[elisp:(browse-youtube \"%s %s\")][%s - %s]]\n"
                           i artist song artist song)))     

      (local-set-keys
        ("u" . (progn (kill-buffer)
                      (display-user-loved-songs (1+ page))))
        ("i" . (when (> page 1)
                 (kill-buffer)
                 (display-user-loved-songs (1- page))))
        ("s" . (choose-song songs))))))

(defun display-album (artist album)
  (with-player-macro "album"    
    (let* ((songs (lastfm-album-get-info artist album))
           ;; Align song durations in one nice column. For this, I need to know
           ;; the longest song name from the album.
           (max-len (cl-loop for entry in songs
                             maximize (length (cadr entry)))))
      
      (insert (format "* %s - %s \n\n" artist album))
      (cl-loop for i from 1
               for entry in songs
               for song = (cadr entry)
               for duration = (format-seconds
                               "%m:%02s" (string-to-number (caddr entry))) 
               do (insert
                   (format (concat "%2s. [[elisp:(browse-youtube \"%s %s\")][%-"
                                   (number-to-string (1+ max-len))
                                   "s]] %s\n")
                           i artist song song duration)))

      (local-set-keys
        ("s" . (choose-song songs))
        ("p" . (play-songs (make-generator songs nil)))))))


(defconst playing-song nil)
(defconst keep-playing t)

(defun play (songs)    
  (when (and keep-playing
             (setf playing-song (next-song songs)))
    (find-youtube-id playing-song #'play-youtube-video)))

(defun open-youtube ()
  "Change it!"
  (find-youtube-id
   playing-song (lambda (id)
                  (browse-url (concat "https://www.youtube.com/watch?v=" id)))))

(defun stop-playing ()
  (setf keep-playing nil
        playing-song nil)
  (mpv-kill))

(defun skip-song () (mpv-kill))
(defun playing-song () playing-song)

(defun play-songs (songs)    
  ;; Play the next song after the player exits (song finished, song skipped, etc.)
  (setf mpv-on-exit-hook
        (lambda (&rest event)
          (unless event
            ;; A kill event took place.
            (play songs))))
  (play songs))

(iter-defun make-generator (songs random)  
  (while songs    
    (let ((song (if random
                    (seq-random-elt songs)
                  (prog1 (car songs)
                    (setf songs (cdr songs))))))
      (iter-yield
       (format "%s %s" (car song) (cadr song))))))

(defun next-song (songs)
  (condition-case nil
      (iter-next songs)
    (iter-end-of-sequence nil)))

(defun user-top-songs (random)
  (make-generator
   (lastfm-user-get-loved-tracks :limit 3) random))

(iter-defun artist-similar-songs (name)
  (while t
    (let* ((artist (cl-first
                    (seq-random-elt
                     (lastfm-artist-get-similar name))))
           (song (cl-first
                  (seq-random-elt
                   (lastfm-artist-get-top-tracks artist)))))
      (iter-yield (format "%s %s" artist song)))))

(iter-defun tag-similar-songs (name)
  (while t
    (let* ((artist (cl-first
                    (seq-random-elt
                     (lastfm-tag-get-top-artists name))))
           (song (cl-first
                  (seq-random-elt
                   (lastfm-artist-get-top-tracks artist)))))
      (iter-yield (format "%s %s" artist song)))))

(defun play-user-loved-songs ()
  (play-songs (user-top-songs nil)))

(defun play-artist-similar-songs (name)
  (play-songs (artist-similar-songs name)))

(defun play-tag-similar-songs (name)
  (play-songs (tag-similar-songs)))
