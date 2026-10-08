#pragma once

#include "Core/Async.h"
#include "Core/Models/RadioModels.h"

#include <QWidget>

#include <memory>
#include <optional>

class QHBoxLayout;
class QLabel;
class QScrollArea;
class QVBoxLayout;

namespace ct {

class RadioView : public QWidget {
    Q_OBJECT

public:
    explicit RadioView(QWidget* parent = nullptr);
    ~RadioView() override;

protected:
    void showEvent(QShowEvent* event) override;
    void resizeEvent(QResizeEvent* event) override;

private:
    void loadCategories();
    Task<void> loadCategoriesAsync(quint64 token);
    void loadRadios();
    Task<void> loadRadiosAsync(quint64 token);
    void selectCategory(const std::optional<QString>& id);
    void render();
    void renderChips();
    void renderList();
    QWidget* buildChip(const QString& title, const std::optional<QString>& id);
    QWidget* buildRadioCard(const RadioStation& radio);
    int gridColumns() const;

    QScrollArea* m_chipScroll = nullptr;
    QHBoxLayout* m_chipLayout = nullptr;
    QLabel* m_subtitle = nullptr;
    QWidget* m_host = nullptr;
    QVBoxLayout* m_hostLayout = nullptr;

    QList<RadioCategory> m_categories;
    std::optional<QString> m_selectedCategoryID;
    QList<RadioStation> m_radios;
    bool m_isLoading = false;
    std::optional<QString> m_errorMessage;
    quint64 m_loadToken = 0;
    bool m_categoriesLoaded = false;
    bool m_loaded = false;
    int m_lastColumns = 0;
    std::shared_ptr<bool> m_alive = std::make_shared<bool>(true);
};

} // namespace ct
